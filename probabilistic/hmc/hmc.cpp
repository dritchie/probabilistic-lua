/*
This file implements the HMC sampling library and is compiled into a shared library.
*/

#include "stan/agrad/agrad.hpp"
#include "stan/model/prob_grad_ad.hpp"
#include "nuts_diaggiven.hpp"
#include "lmc.hpp"

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

extern "C"
{
	// The AD arithmetic functions
	#include "adMath.cpp"
}


///////////////////////////////////////////////////////////////////////
//							HMC Samplers 							 //
///////////////////////////////////////////////////////////////////////


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
		return *((stan::agrad::var*)&lp);
	}
	virtual double grad_log_prob(std::vector<double>& params_r, 
                                   std::vector<int>& params_i, 
                                   std::vector<double>& gradient,
                                   std::ostream* output_stream = 0)
	{
		return stan::model::prob_grad_ad::grad_log_prob(params_r, params_i, gradient, output_stream);
	}
};

// HMC sampler types
enum HMCSamplerType
{
	Langevin = 0,
	NUTS
};


// Packages together a stan sampler and the model it samples from
struct HMCSamplerState
{
private:
	HMCSamplerType type;
public:
	FunctionPoinderModel model;
	stan::mcmc::ppl_hmc<boost::mt19937>* sampler;
	HMCSamplerState(HMCSamplerType t) : type(t), model(), sampler(NULL) {}
	~HMCSamplerState()
	{
		if (sampler) delete sampler;
	}
	void init(const std::vector<double>& params_r)
	{
		if (sampler == NULL)
		{
			std::vector<int> params_i;
			if (type == Langevin)
				sampler = new stan::mcmc::lmc<>(model, params_r, params_i, 0.5);	// Last param is partial momentum refreshment
			else if (type == NUTS)
				sampler = new stan::mcmc::nuts_diaggiven<>(model, params_r, params_i);
		}
		else
		{
			sampler->set_params_r(params_r);
			sampler->reset_inv_masses(params_r.size());
		}
	}
};

// The C interface
extern "C"
{
	EXPORT double getValue(num n)
	{
		return ((stan::agrad::var*)&n)->val();
	}

	EXPORT num makeNum(double val)
	{
		stan::agrad::var v(val);
		return *(num*)&v;
	}

	EXPORT HMCSamplerState* newSampler(int type)
	{
		HMCSamplerType stype = (HMCSamplerType)type;
		return new HMCSamplerState(stype);
	}

	EXPORT void deleteSampler(HMCSamplerState* s)
	{
		delete s;
	}

	EXPORT void setLogprobFunction(HMCSamplerState* s, LogProbFunction lpfn)
	{
		s->model.setLogprobFunction(lpfn);
	}

	EXPORT int nextSample(HMCSamplerState* s, double* vals)
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

		memcpy(vals, &newvals[0], numparams*sizeof(double));
		return accepted;
	}

	EXPORT void setVariableValues(HMCSamplerState* s, int numvals, double* vals)
	{
		if (s->model.lpfn == NULL)
		{
			hmcError("Cannot set variable values before log prob function has been set.");
		}

		std::vector<double> params_r(numvals);
		memcpy(&params_r[0], vals, numvals*sizeof(double));

		s->model.set_num_params_r(numvals);

		// Initialize the sampler with the new values.
		s->init(params_r);
	}

	EXPORT void setVariableInvMasses(HMCSamplerState* s, double* invmasses)
	{
		std::vector<double> imasses(s->model.num_params_r());
		memcpy(&imasses[0], invmasses, s->model.num_params_r()*sizeof(double));
		s->sampler->set_inv_masses(imasses);
	}

	EXPORT void recomputeLogProb(HMCSamplerState* s)
	{
		s->sampler->recompute_log_prob();
	}
}


///////////////////////////////////////////////////////////////////////
//							  T3 Sampler							 //
///////////////////////////////////////////////////////////////////////






