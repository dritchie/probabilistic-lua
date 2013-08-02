#ifndef __STAN__MCMC__NUTS_DIAGGIVEN_H__
#define __STAN__MCMC__NUTS_DIAGGIVEN_H__

#include <ctime>
#include <cstddef>
#include <iostream>
#include <vector>

#include <boost/random/normal_distribution.hpp>
#include <boost/random/mersenne_twister.hpp>
#include <boost/random/variate_generator.hpp>
#include <boost/random/uniform_01.hpp>

#include <stan/math/functions/dot.hpp>
#include <stan/math/functions/dot_self.hpp>
#include <stan/math/functions/min.hpp>
#include <stan/math/functions/sub.hpp>
#include <stan/mcmc/adaptive_sampler.hpp>
#include <stan/mcmc/dualaverage.hpp>
#include <stan/mcmc/hmc_base.hpp>
#include <stan/mcmc/util.hpp>

namespace stan {

  namespace mcmc {

    /**
     * No-U-Turn Sampler (NUTS) with given diagonal mass matrix.
     *
     * The NUTS sampler requires a probability model with the ability
     * to compute gradients, characterized as an instance of
     * <code>prob_grad</code>.  
     */
    template <class BaseRNG = boost::mt19937>
    class nuts_diaggiven : public hmc_base<BaseRNG> {
    private:

      // Stop immediately if H < u - _maxchange
      const double _maxchange;

      // Limit tree depth
      const int _maxdepth;

      // depth of last sample taken (-1 before any samples)
      int _lastdepth;

      // Vector of per-parameter inverse masses.
      std::vector<double> _inv_masses;

      /**
       * Determine whether we've started to make a "U-turn" at either end
       * of the position-state trajectory beginning with {xminus, mminus}
       * and ending with {xplus, mplus}.
       *
       * @return false if we've made a U-turn, true otherwise.
       */
      inline static bool compute_criterion(std::vector<double>& xplus,
                                           std::vector<double>& xminus,
                                           std::vector<double>& mplus,
                                           std::vector<double>& mminus) {
        std::vector<double> total_direction;
        stan::math::sub(xplus, xminus, total_direction);
        return stan::math::dot(total_direction, mminus) > 0
            && stan::math::dot(total_direction, mplus) > 0;
      }

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

      /**
       * Construct a No-U-Turn Sampler (NUTS) for the specified model,
       * using the specified step size and number of leapfrog steps,
       * with the specified random seed for randomization.
       *
       * If the same seed is used twice, the series of samples should
       * be the same.  This property is most helpful for testing.  If no
       * random seed is specified, the <code>std::time(0)</code> function is
       * called from the <code>ctime</code> library.
       * 
       * @param model Probability model with gradients.
       * @param maxdepth Maximum depth for searching for a U-Turn. Default is 10.
       * @param epsilon Optional (initial) Hamiltonian dynamics simulation
       * step size. If not specified or set < 0, find_reasonable_parameters()
       * will be called to initialize epsilon.
       * @param epsilon_pm Plus/minus range for uniformly sampling epsilon around
       * its value.
       * @param epsilon_adapt True if epsilon is adapted during warmup.
       * @param delta Optional target value between 0 and 1 used to tune 
       * epsilon. Lower delta => higher epsilon => more efficiency, unless
       * epsilon gets _too_ big in which case efficiency suffers.
       * If not specified, defaults to the usually reasonable value of 0.6.
       * @param gamma Gamma tuning parameter for dual averaging adaptation.
       * @param base_rng Optional Seed for random number generator; if not
       * specified, generate new seed based on system time.
       */
      nuts_diaggiven(stan::model::prob_grad& model,
           const std::vector<double>& params_r,
           const std::vector<int>& params_i,
           int maxdepth = 10,
           double epsilon = -1,
           double epsilon_pm = 0.0,
           bool epsilon_adapt = true,
           double delta = 0.6, 
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
          _maxchange(-1000),
          _maxdepth(maxdepth),
          _lastdepth(-1),
          _inv_masses(model.num_params_r(), 1.0)
      {
        // start at 10 * epsilon because NUTS cheaper for larger epsilon
        this->adaptation_init(10.0);
      }

      /**
       * Destructor.
       *
       * The implementation for this class is a no-op.
       */
      ~nuts_diaggiven() { }

      /**
       * Return the next sample.
       *
       * @return The next sample.
       */
      virtual sample next_impl() {
        // Initialize the algorithm
        std::vector<double> mminus(this->_model.num_params_r());
        for (size_t i = 0; i < mminus.size(); ++i)
          mminus[i] = this->_rand_unit_norm() * this->_inv_masses[i];
        std::vector<double> mplus(mminus);
        // The log-joint probability of the momentum and position terms, i.e.
        // -(kinetic energy + potential energy)
        double H0 = -0.5 * stan::math::dot_self(mminus) + this->_logp;

        std::vector<double> gradminus(this->_g);
        std::vector<double> gradplus(this->_g);
        std::vector<double> xminus(this->_x);
        std::vector<double> xplus(this->_x);

        // Sample the slice variable
        double u = log(this->_rand_uniform_01()) + H0;
        int nvalid = 1;
        int direction = 2 * (this->_rand_uniform_01() > 0.5) - 1;
        bool criterion = true;

        // Repeatedly double the set of points we've visited
        std::vector<double> newx, newgrad, dummy1, dummy2, dummy3;
        double newlogp = -1;
        double prob_sum = -1;
        int newnvalid = -1;
        int n_considered = 0;
        // for-loop with depth outside to set lastdepth
        int depth = 0;

        double epsilon = this->_epsilon;
        // only vary epsilon after done adapting
        if (!this->adapting() && this->varying_epsilon()) { 
          double low = epsilon * (1.0 - this->_epsilon_pm);
          double high = epsilon * (1.0 + this->_epsilon_pm);
          double range = high - low;
          epsilon = low + (range * this->_rand_uniform_01());
        }
        this->_epsilon_last = epsilon; // use epsilon_last in tree build

        while (criterion && (_maxdepth < 0 || depth < _maxdepth)) {
          direction = 2 * (this->_rand_uniform_01() > 0.5) - 1;
          if (direction == -1)
            build_tree(xminus, mminus, gradminus, u, direction, depth,
                       H0, xminus, mminus, gradminus, dummy1, dummy2, dummy3,
                       newx, newgrad, newlogp, newnvalid, criterion, prob_sum,
                       n_considered);
          else
            build_tree(xplus, mplus, gradplus, u, direction, depth,
                       H0, dummy1, dummy2, dummy3, xplus, mplus, gradplus, 
                       newx, newgrad, newlogp, newnvalid, criterion, prob_sum,
                       n_considered);
          // We can't look at the results of this last doubling if criterion==false
          if (!criterion)
            break;
          criterion = compute_criterion(xplus, xminus, mplus, mminus);
          // Metropolis-Hastings to determine if we can jump to a point in
          // the new half-tree
          if (this->_rand_uniform_01() < float(newnvalid) / (1e-100+float(nvalid))) {
            this->_x = newx;
            this->_g = newgrad;
            this->_logp = newlogp;
          }
          nvalid += newnvalid;
//          fprintf(stderr, "depth = %d, this->_logp = %g\n", depth, this->_logp);
          ++depth;
        }
        _lastdepth = depth;

        // Now we just have to update epsilon, if adaptation is on.
        double adapt_stat = prob_sum / float(n_considered);
        if (this->adapting()) {
          double adapt_g = adapt_stat - this->_delta;
          std::vector<double> gvec(1, -adapt_g);
          std::vector<double> result;
          this->_da.update(gvec, result);
          this->_epsilon = exp(result[0]);
        }
        std::vector<double> result;
        this->_da.xbar(result);
//         fprintf(stderr, "xbar = %f\n", exp(result[0]));
        double avg_eta = 1.0 / this->n_steps();
        this->update_mean_stat(avg_eta,adapt_stat);

        mcmc::sample s(this->_x, this->_z, this->_logp);
        return s;
      }

      virtual void write_sampler_param_names(std::ostream& o) {
        o << "treedepth__,";
        if (this->_epsilon_adapt || this->varying_epsilon())
          o << "stepsize__,";
      }

      virtual void write_sampler_params(std::ostream& o) {
        o << _lastdepth << ',';
        if (this->_epsilon_adapt || this->varying_epsilon())
          o << this->_epsilon_last << ',';
      }

      virtual void get_sampler_param_names(std::vector<std::string>& names) {
        names.clear();
        names.push_back("treedepth__");
        if (this->_epsilon_adapt || this->varying_epsilon())
          names.push_back("stepsize__");
      }
      virtual void get_sampler_params(std::vector<double>& values) {
        values.clear();
        values.push_back(_lastdepth);
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

      /**
       * The core recursion in NUTS.
       *
       * @param[in] x The position value to start from.
       * @param[in] m The momentum value to start from.
       * @param[in] grad The gradient at the initial position.
       * @param[in] u The slice variable.
       * @param[in] direction Simulate backwards if -1, forwards if 1.
       * @param[in] depth The depth of the tree to build---we'll run 2^depth
       * leapfrog steps.
       * @param[in] H0 The joint probability of the position-momentum we started
       * from initially---used to compute statistic to adapt epsilon.
       * @param[out] xminus Returns the position of the backwardmost leaf of this
       * subtree.
       * @param[out] mminus Returns the momentum of the backwardmost leaf of this
       * subtree.
       * @param[out] gradminus Returns the gradient at xminus.
       * @param[out] xplus Returns the position of the forwardmost leaf of this
       * subtree.
       * @param[out] mplus Returns the momentum of the forwardmost leaf of this
       * subtree.
       * @param[out] gradplus Returns the gradient at xplus.
       * @param[out] newx Returns the new position sample selected from
       * this subtree.
       * @param[out] newgrad Returns the gradient at the new sample selected from
       * this subtree.
       * @param[out] newlogp Returns the log-probability of the new sample selected
       * from this subtree.
       * @param[out] nvalid Returns the number of usable points in the subtree.
       * @param[out] criterion Returns true if the subtree is usable, false if not.
       * @param[out] prob_sum Returns the sum of the HMC acceptance probabilities
       * at each point in the subtree.
       * @param[out] n_considered Returns the number of states in the subtree.
       */
      void build_tree(const std::vector<double>& x, 
                      const std::vector<double>& m,
                      const std::vector<double>& grad,
                      double u,
                      int direction,
                      int depth, 
                      double H0,
                      std::vector<double>& xminus,
                      std::vector<double>& mminus,
                      std::vector<double>& gradminus,
                      std::vector<double>& xplus,
                      std::vector<double>& mplus,
                      std::vector<double>& gradplus,
                      std::vector<double>& newx,
                      std::vector<double>& newgrad,
                      double& newlogp,
                      int& nvalid, 
                      bool& criterion, 
                      double& prob_sum, 
                      int& n_considered) {
        if (depth == 0) {   // base case
          xminus = x;
          gradminus = grad;
          mminus = m;
          newlogp = diag_leapfrog(this->_model, this->_z, _inv_masses, 
                                  xminus, mminus, gradminus, 
                                  direction * this->_epsilon_last,
                                  this->_error_msgs, this->_output_msgs);
          newx = xminus;
          newgrad = gradminus;
          xplus = xminus;
          mplus = mminus;
          gradplus = gradminus;
          double newH = newlogp - 0.5 * stan::math::dot_self(mminus);
          if (newH != newH) // treat nan as -inf
            newH = -std::numeric_limits<double>::infinity();
          nvalid = newH > u;
          criterion = newH - u > _maxchange;
          prob_sum = stan::math::min(1, exp(newH - H0));
          n_considered = 1;
          this->nfevals_plus_eq(1);
        } else {            // depth >= 1
          build_tree(x, m, grad, u, direction, depth-1, H0, xminus, mminus,
                     gradminus, xplus, mplus, gradplus, newx, newgrad, newlogp,
                     nvalid, criterion, prob_sum, n_considered);
          if (criterion) {
            std::vector<double> dummy1, dummy2, dummy3;
            std::vector<double> newx2;
            std::vector<double> newgrad2;
            double newlogp2;
            int nvalid2;
            bool criterion2;
            double prob_sum2;
            int n_considered2;
            if (direction == -1)
              build_tree(xminus, mminus, gradminus, u, direction, depth-1, H0,
                         xminus, mminus, gradminus, dummy1, dummy2, dummy3,
                         newx2, newgrad2, newlogp2, nvalid2, criterion2, 
                         prob_sum2, n_considered2);
            else
              build_tree(xplus, mplus, gradplus, u, direction, depth-1, H0,
                         dummy1, dummy2, dummy3, xplus, mplus, gradplus, 
                         newx2, newgrad2, newlogp2, nvalid2, criterion2,
                         prob_sum2, n_considered2);
            if (criterion && 
                (this->_rand_uniform_01() 
                 < float(nvalid2) / float(nvalid+nvalid2))) {
              newx = newx2;
              newgrad = newgrad2;
              newlogp = newlogp2;
            }
            n_considered += n_considered2;
            prob_sum += prob_sum2;
            criterion &= criterion2;
            nvalid += nvalid2;
          }
          criterion &= compute_criterion(xplus, xminus, mplus, mminus);
        }
      }



    };


  }

}

#endif