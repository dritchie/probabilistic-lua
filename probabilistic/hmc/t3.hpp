#ifndef __STAN__MCMC__T3_H_
#define __STAN__MCMC__T3_H_

#include <ctime>
#include <cstddef>
#include <iostream>
#include <vector>

#include <boost/random/normal_distribution.hpp>
#include <boost/random/mersenne_twister.hpp>
#include <boost/random/variate_generator.hpp>
#include <boost/random/uniform_01.hpp>

#include <stan/math/functions/min.hpp>
#include <stan/mcmc/adaptive_sampler.hpp>
#include <stan/mcmc/dualaverage.hpp>
#include <stan/mcmc/hmc_base.hpp>
#include <stan/mcmc/util.hpp>

#include "ppl_hmc.hpp"

#include "stan/agrad/agrad.hpp"
#include "stan/model/prob_grad_ad.hpp"

extern "C"
{
	#include "num.h"
}


// A custom subclass of prob_grad_ad that evaluates log probabilities
// by interpolating two function pointer functions.
class InterpolatedFunctionPointerModel : public stan::model::prob_grad_ad
{
public:
	LogProbFunction lpfn1;
	LogProbFunction lpfn2;
	double alpha;
	double globalTemp;
	InterpolatedFunctionPointerModel() :
		stan::model::prob_grad_ad(0), lpfn1(NULL), lpfn2(NULL),
		alpha(0.0), globalTemp(1.0) {}
	void setLogprobFunctions(LogProbFunction lp1, LogProbFunction lp2)
	{ lpfn1 = lp1; lpfn2 = lp2; }
	void setAlpha(double a) { alpha = a; }
	void setGlobalTemp(double t) { globalTemp = t; }
	virtual stan::agrad::var log_prob(std::vector<stan::agrad::var>& params_r, 
			                  std::vector<int>& params_i,
			                  std::ostream* output_stream = 0)
	{
		num* params = (num*)(&params_r[0]);
		num lp1 = lpfn1(params);
		num lp2 = lpfn2(params);
		stan::agrad::var interp = (1.0-alpha) * (*((stan::agrad::var*)&lp1)) +
					 alpha * (*((stan::agrad::var*)&lp2));
		return globalTemp * interp;
	}
	virtual double grad_log_prob(std::vector<double>& params_r, 
                                   std::vector<int>& params_i, 
                                   std::vector<double>& gradient,
                                   std::ostream* output_stream = 0)
	{
		return stan::model::prob_grad_ad::grad_log_prob(params_r, params_i, gradient, output_stream);
	}
};

namespace stan
{
	namespace mcmc
	{
		/*
		Trans-dimensional tempered trajectories (T3) sampler
		*/
		template <class BaseRNG = boost::mt19937>
		class t3 : public ppl_hmc<BaseRNG>
		{
		private:

      		// Parameter controlling global tempering (< 1)
      		double _globalTempMult;

      		// Number of leapfrog steps to take
      		int _L;

      		// We may borrow certain stats from this sampler.
      		stan::mcmc::ppl_hmc<BaseRNG>* _oracle;

      		// Indices of old/new variables in the extended variable space
      		std::vector<int> _oldVarIndices;
      		std::vector<int> _newVarIndices;

			// Three possible cases for global tempering:
	      	//  - We're in the first half of the trajectory
	      	//  - We're in the second half of the trajectory
	      	//  - We're at the exact midpoint of an odd-length trajectory
	      	enum TemperingTrajectoryCase
	      	{
	      		FirstHalf, Midpoint, SecondHalf
	      	};   		

      		// Returns the new log probability of x and m
	      // Catches domain errors and sets logp as -inf.
	      // Uses a diagonal mass matrix
	      static double tempered_diag_leapfrog(stan::model::prob_grad& model, 
	                           std::vector<int> z, 
	                           const std::vector<double>& inv_masses,
	                           std::vector<double>& x, std::vector<double>& m,
	                           std::vector<double>& g, double epsilon,
	                           double sqrtTempMult, int iter, int numIters,
	                           std::ostream* error_msgs = 0,
	                           std::ostream* output_msgs = 0) {

	      	// Determine the trajectory case (assumes zero-based indexing, naturally)
	      	TemperingTrajectoryCase tcase;
	      	if (numIters % 2 != 0 && iter == numIters/2)
	      		tcase = Midpoint;
	      	else if (iter < numIters/2)
	      		tcase = FirstHalf;
	      	else
	      		tcase = SecondHalf;

	      	double mult = (tcase == SecondHalf ? 1.0/sqrtTempMult : sqrtTempMult);
	        for (size_t i = 0; i < m.size(); i++)
	        {
	          m[i] += 0.5 * epsilon * g[i];
	          m[i] *= mult;
	      	}
	        for (size_t i = 0; i < x.size(); i++)
	          x[i] += epsilon * inv_masses[i] * m[i];
	        double logp;
	        try {
	          logp = model.grad_log_prob(x, z, g, output_msgs);
	        } catch (std::domain_error e) {
	          write_error_msgs(error_msgs,e);
	          logp = -std::numeric_limits<double>::infinity();
	        }
	        mult = (tcase == FirstHalf ? sqrtTempMult : 1.0/sqrtTempMult);
	        for (size_t i = 0; i < m.size(); i++)
	        {
	          m[i] += 0.5 * epsilon * g[i];
	          m[i] *= mult;
	      	}
	        return logp;
	      }

		public:

			t3(stan::model::prob_grad& model,
				const std::vector<double>& params_r,
				const std::vector<int>& params_i,
				int L = 100,
				double globalTempMult = 1.0,
				stan::mcmc::ppl_hmc<BaseRNG>* oracle = NULL,
				double epsilon = -1,
				double epsilon_pm = 0.0,
				bool epsilon_adapt = true,
				double delta = 0.65,
				double gamma = 0.05,
				BaseRNG base_rng = BaseRNG(std::time(0)))
			: ppl_hmc<BaseRNG>(model,
								params_r,
								params_i,
								delta,
								gamma,
								epsilon,
								epsilon_pm,
								epsilon_adapt,
								base_rng),
			_globalTempMult(globalTempMult),
			_L(L),
			_oracle(oracle)
			{
				this->adaptation_init(1.0);
			}

			~t3() { }

			virtual sample next_impl()
			{
				InterpolatedFunctionPointerModel& model = (InterpolatedFunctionPointerModel&)this->_model;

				// Assumes that 'reset_inv_masses' has been called prior to this.

				// Sample initial momentum
				std::vector<double> m(this->_model.num_params_r());
				for (size_t i = 0; i < m.size(); ++i)
					m[i] = this->_rand_unit_norm() * this->_inv_masses[i];

				// Initial Hamiltonian
				double fwdKineticEnergy = 0.0;
				for (size_t i = 0; i < m.size(); i++)
					fwdKineticEnergy += m[i]*m[i] * this->_inv_masses[i];
				fwdKineticEnergy /= 2.0;
				double H = fwdKineticEnergy - this->_logp;

				double newlogp;

				// // TODO: Oracle-related stuff?
				// if (_oracle != NULL) 
				// 	this->_epsilon = _oracle->get_epsilon();

				this->_epsilon_last = this->_epsilon;

				// Do leapfrog steps
				double globalTemp = 1.0;
				double sqrtTempMult = sqrt(_globalTempMult);
				for (unsigned int i = 0; i < _L; i++)
				{
					double alpha = ((double)i)/(_L-1);
					model.setAlpha(alpha);

					for (unsigned int i = 0; i < _oldVarIndices.size(); i++)
						this->_inv_masses[_oldVarIndices[i]] = (1.0 - alpha);
					for (unsigned int i = 0; i < _newVarIndices.size(); i++)
						this->_inv_masses[_newVarIndices[i]] = alpha;

					if (alpha <= 0.5)
						globalTemp *= _globalTempMult;
					else
						globalTemp /= _globalTempMult;
					model.setGlobalTemp(globalTemp);

					// newlogp = tempered_diag_leapfrog(this->_model, this->_z, this->_inv_masses,
					// 							     this->_x, m, this->_g, this->_epsilon_last,
					// 							     sqrtTempMult, 0, _L,
					// 					   		     this->_error_msgs, this->_output_msgs);

					newlogp = ppl_hmc<>::diag_leapfrog(this->_model, this->_z, this->_inv_masses,
													   this->_x, m, this->_g, this->_epsilon_last,
											   		   this->_error_msgs, this->_output_msgs);
				}
				this->nfevals_plus_eq(_L);

				// New Hamiltonian
				double rvsKineticEnergy = 0.0;
				for (size_t i = 0; i < m.size(); i++)
					rvsKineticEnergy += m[i]*m[i] * this->_inv_masses[i];
				rvsKineticEnergy /= 2.0;
				double H_new = rvsKineticEnergy - newlogp;

				// Compute normal HMC accept/reject threshold,
				// use this for adaptation
				double acceptThresh = exp(-H_new + H);
				double adapt_stat = stan::math::min(1, acceptThresh);
		        if (adapt_stat != adapt_stat)
		          adapt_stat = 0;
		        if (this->adapting()) {
		          double adapt_g = adapt_stat - this->_delta;
		          std::vector<double> gvec(1, -adapt_g);
		          std::vector<double> result;
		          this->_da.update(gvec, result);
		          this->_epsilon = exp(result[0]);
		        }
		        std::vector<double> result;
		        this->_da.xbar(result);
		        double avg_eta = 1.0 / this->n_steps();
		        this->update_mean_stat(avg_eta,adapt_stat);

		        // Return the current state of things, storing
		        // the kinetic energy difference in the sample's _logp field.
				return mcmc::sample(this->_x, this->_z, -rvsKineticEnergy + fwdKineticEnergy);
			}

			virtual void write_sampler_param_names(std::ostream& o) {
				if (this->_epsilon_adapt || this->varying_epsilon())
				  o << "stepsize__,";
			}

			virtual void write_sampler_params(std::ostream& o) {
				if (this->_epsilon_adapt || this->varying_epsilon())
				  o << this->_epsilon_last << ',';
			}

			virtual void get_sampler_param_names(std::vector<std::string>& names) {
				names.clear();
				if (this->_epsilon_adapt || this->varying_epsilon())
				  names.push_back("stepsize__");
			}
			virtual void get_sampler_params(std::vector<double>& values) {
				values.clear();
				if (this->_epsilon_adapt || this->varying_epsilon())
				  values.push_back(this->_epsilon_last);
			}

			void set_var_indices(const std::vector<int>& oldvi, const std::vector<int>& newvi)
			{
				_oldVarIndices = oldvi;
				_newVarIndices = newvi;
			}
		};
	}

}


#endif