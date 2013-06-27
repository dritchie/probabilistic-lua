/*
This file implements the HMC sampling library and is compiled into a shared library.
*/

#include "stan/agrad/agrad.hpp"
#include "stan/model/prob_grad_ad.hpp"
#include "stan/mcmc/nuts.hpp"

#define EXPORT __declspec(dllexport)

// A custom subclass of prob_grad_ad that evaluates log probabilities via
// a function pointer.
typedef stan::agrad::var(*LogProbFunction)(stan::agrad::var*);
class FunctionPoinderModel : public stan::model::prob_grad_ad
{
private:
	LogProbFunction lpfn;
public:
	FunctionPoinderModel() : stan::model::prob_grad_ad(0), lpfn(NULL) {}
	void setLogprobFunction(LogProbFunction lp) { lpfn = lp; }
	stan::agrad::var log_prob(std::vector<stan::agrad::var>& params_r, 
                              std::vector<int>& params_i,
                              std::ostream* output_stream = 0)
	{
		return lpfn(&params_r[0]);
	}
};

// Packages together a stan sampler and the model it samples from
struct SamplerState
{
public:
	FunctionPoinderModel model;
	stan::mcmc::nuts<boost::mt19937>* sampler;
	SamplerState() : model(), sampler(NULL) {}
}; 

// The C interface
extern "C"
{
	EXPORT SamplerState* newSampler()
	{
		return new SamplerState;
	}

	EXPORT void deleteSampler(SamplerState* s)
	{
		delete s;
	}

	EXPORT void setLogprobFunction(SamplerState* s, LogProbFunction lpfn)
	{
		s->model.setLogprobFunction(lpfn);
	}

	EXPORT void setVariableValues(SamplerState* s, int numvals, double* vals)
	{
		std::vector<double> params_r(numvals);
		memcpy(&params_r[0], vals, numvals*sizeof(double));

		// Initialize the sampler if this is the first time.
		if (s->sampler == NULL)
		{
			std::vector<int> params_i;
			s->sampler = new stan::mcmc::nuts<>(s->model, params_r, params_i);
		}
		else
		{
			s->model.set_num_params_r(numvals);
			s->sampler->set_params_r(params_r);
		}
	}

	EXPORT int nextSample(SamplerState* s, double* vals)
	{
		size_t numparams = s->model.num_params_r();
		stan::mcmc::sample samp = s->sampler->next();
		const std::vector<double>& newvals = samp.params_r();
		bool accepted = true;
		for (unsigned int i = 0; i < numparams; i++)
		{
			if (newvals[i] != vals[i])
			{
				accepted = false;
				break;
			}
		}
		memcpy(vals, &(samp.params_r())[0], numparams*sizeof(double));
		return accepted;
	}
}