#ifndef __STAN__MCMC__PPL_HMC_H__
#define __STAN__MCMC__PPL_HMC_H__

#include <ctime>
#include <cstddef>
#include <iostream>
#include <vector>

#include <boost/random/normal_distribution.hpp>
#include <boost/random/mersenne_twister.hpp>
#include <boost/random/variate_generator.hpp>
#include <boost/random/uniform_01.hpp>

#include <stan/mcmc/hmc_base.hpp>

namespace stan {

	namespace mcmc {

		template <class BaseRNG = boost::mt19937>
		class ppl_hmc : public hmc_base<BaseRNG>
		{
		protected:

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

	    	ppl_hmc(stan::model::prob_grad& model,
				const std::vector<double>& params_r,
				const std::vector<int>& params_i,
				double delta,
				double gamma,
				double epsilon = -1,
				double epsilon_pm = 0.0,
				bool epsilon_adapt = true,
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