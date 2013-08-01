/*
This file implements the HMC sampling library and is compiled into a shared library.
*/

#include "stan/agrad/agrad.hpp"
#include "stan/model/prob_grad_ad.hpp"
#include "nuts_diaggiven.hpp"

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__ ((visibility ("default")))
#endif

void hmcError(std::string message)
{
	printf("libhmc: %s\n", message.c_str());
	throw 0;
}


// C 'wrapper' around stan's dual number class
extern "C"
{
	#include "num.h"
	typedef num(*LogProbFunction)(num*);
}

// A custom subclass of prob_grad_ad that evaluates log probabilities via
// a function pointer.
class FunctionPoinderModel : public stan::model::prob_grad_ad
{
public:
	LogProbFunction lpfn;
	FunctionPoinderModel() : stan::model::prob_grad_ad(0), lpfn(NULL) {}
	void setLogprobFunction(LogProbFunction lp) { lpfn = lp; }
	virtual stan::agrad::var log_prob(std::vector<stan::agrad::var>& params_r, 
			                  std::vector<int>& params_i,
			                  std::ostream* output_stream = 0)
	{
		num* params = (num*)(&params_r[0]);
		num lp = lpfn(params);
		//return stan::agrad::var((stan::agrad::vari*)lp.impl);
		return *((stan::agrad::var*)&lp);
	}
};

// Packages together a stan sampler and the model it samples from
struct SamplerState
{
public:
	FunctionPoinderModel model;
	stan::mcmc::nuts_diaggiven<boost::mt19937>* sampler;
	SamplerState() : model(), sampler(NULL) {}
}; 

// The C interface
extern "C"
{
	EXPORT double getValue(num n)
	{
		//return stan::agrad::var((stan::agrad::vari*)n.impl).val();
		return ((stan::agrad::var*)&n)->val();
	}

	EXPORT num makeNum(double val)
	{
		stan::agrad::var v(val);
		return *(num*)&v;
	}

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
		if (s->model.lpfn == NULL)
		{
			hmcError("Cannot set variable values before log prob function has been set.");
		}

		std::vector<double> params_r(numvals);
		memcpy(&params_r[0], vals, numvals*sizeof(double));

		s->model.set_num_params_r(numvals);

		// Initialize the sampler if this is the first time.
		if (s->sampler == NULL)
		{
			std::vector<int> params_i;
			s->sampler = new stan::mcmc::nuts_diaggiven<>(s->model, params_r, params_i);
		}
		else
		{
			s->sampler->set_params_r(params_r);
			s->sampler->reset_inv_masses(numvals);
		}
	}

	EXPORT void setVariableInvMasses(SamplerState* s, double* invmasses)
	{
		std::vector<double> imasses(s->model.num_params_r());
		memcpy(&imasses[0], invmasses, s->model.num_params_r()*sizeof(double));
		s->sampler->set_inv_masses(imasses);
	}

	EXPORT void toggleStepSizeAdaptation(SamplerState* s, int flag)
	{
		if (flag)
			s->sampler->adapt_on();
		else
			s->sampler->adapt_off();
	}

	EXPORT void recomputeLogProb(SamplerState* s)
	{
		s->sampler->recompute_log_prob();
	}

	EXPORT int nextSample(SamplerState* s, double* vals)
	{
		size_t numparams = s->model.num_params_r();

		stan::mcmc::sample samp = s->sampler->next();
		const std::vector<double>& newvals = samp.params_r();
		bool accepted = false;
		for (unsigned int i = 0; i < numparams; i++)
		{
			if (newvals[i] != vals[i])
			{
				accepted = true;
				break;
			}
		}

		// // DEBUG
		// std::vector<double> params;
		// s->sampler->get_sampler_params(params);
		// printf("logprob: %g  |  step size: %g\n", samp.log_prob(), params[1]);

		memcpy(vals, &newvals[0], numparams*sizeof(double));
		return accepted;
	}

	// The AD arithmetic functions
	#include "adMath.cpp"
}




