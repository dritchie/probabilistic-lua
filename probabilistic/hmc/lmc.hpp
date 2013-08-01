#ifndef __STAN__MCMC__LMC_H_
#define __STAN__MCMC__LMC_H_

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

namespace stan
{
	namespace mcmc
	{
		/*
		Langevin Monte Carlo sampler
		*/
		template <class BaseRNG = boost::mt19937>
		class lmc : public hmc_base<BaseRNG>
		{
		private:

			// Vector of per-parameter inverse masses.
      		std::vector<double> _inv_masses;

			/* Alternate version of function in util.hpp */
			// Returns the new log probability of x and m
			// Catches domain errors and sets logp as -inf.
			// Uses a diagonal mass matrix
			static double diag_leapfrog(stan::model::prob_grad& model, 
			                   std::vector<int> z, 
			                   const std::vector<double>& inv_masses,
			                   std::vector<double>& x, std::vector<double>& m,
			                   std::vector<double>& g, double epsilon,
			                   std::ostream* error_msgs = 0,
			                   std::ostream* output_msgs = 0) {
				//printf("\neps: %g\n", epsilon);
				for (size_t i = 0; i < m.size(); i++)
				  m[i] += 0.5 * epsilon * g[i];
				for (size_t i = 0; i < x.size(); i++)
				  x[i] += epsilon * inv_masses[i] * m[i];
				double logp;
				try {
				  logp = model.grad_log_prob(x, z, g, output_msgs);
				} catch (std::domain_error e) {
				  write_error_msgs(error_msgs,e);
				  logp = -std::numeric_limits<double>::infinity();
				}
				for (size_t i = 0; i < m.size(); i++)
				  m[i] += 0.5 * epsilon * g[i];
				return logp;
			}

		public:

			lmc(stan::model::prob_grad& model,
				const std::vector<double>& params_r,
				const std::vector<int>& params_i,
				double epsilon = -1,
				double epsilon_pm = 0.0,
				bool epsilon_adapt = true,
				// Optimal for HMC is 0.65, for LMC is 0.57. Perhaps partial momentum
				// refreshment puts us somewhere in between?
				double delta = 0.61,
				double gamma = 0.05,
				BaseRNG base_rng = BaseRNG(std::time(0)))
			: hmc_base<BaseRNG>(model,
								params_r,
								params_i,
								epsilon,
								epsilon_pm,
								epsilon_adapt,
								delta,
								gamma,
								base_rng),
			_inv_masses(model.num_params_r(), 1.0)
			{
				this->adaptation_init(10.0);
			}

			~lmc() { }

			virtual sample next_impl()
			{
				this->_epsilon_last = this->_epsilon;

				// TODO: Partial momentum refreshment?
				std::vector<double> momentum(this->_model.num_params_r());
				for (size_t i = 0; i < momentum.size(); ++i)
					momentum[i] = this->_rand_unit_norm() * this->_inv_masses[i];

				// Initial Hamiltonian
				double H = 0.0;
				for (size_t i = 0; i < momentum.size(); i++)
					H += momentum[i]*momentum[i] / _inv_masses[i];
				H = H / 2.0 - this->_logp;

				// Leapfrog step
				std::vector<double> x_new(this->_x);
				std::vector<double> g_new = (this->_g);
				double newlogp = diag_leapfrog(this->_model, this->_z, _inv_masses, x_new, momentum, g_new, this->_epsilon_last,
											   this->_error_msgs, this->_output_msgs);
				this->nfevals_plus_eq(1);

				// New Hamiltonian
				double H_new = 0.0;
				for (size_t i = 0; i < momentum.size(); i++)
					H_new += momentum[i]*momentum[i] / _inv_masses[i];
				H_new = H_new / 2.0 - newlogp;

				double acceptThresh = exp(-H_new + H);
				if (this->_rand_uniform_01() < acceptThresh)
				{
					this->_x = x_new;
					this->_g = g_new;
					this->_logp = newlogp;
				}

				// Adaptation
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

		        // Return
				return mcmc::sample(this->_x, this->_z, this->_logp);
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

			void set_inv_masses(const std::vector<double>& invmasses)
			{
				_inv_masses = invmasses;
			}

			void reset_inv_masses(size_t num)
			{
				_inv_masses = std::vector<double>(num, 1.0);
			}

			void recompute_log_prob()
			{
				this->_logp = this->_model.grad_log_prob(this->_x,this->_z,this->_g);
			}
		};
	}

}


#endif