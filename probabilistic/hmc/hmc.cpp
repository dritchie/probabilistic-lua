/*
This file implements the HMC sampling library and is compiled into a shared library.
*/

#include "stan/agrad/agrad.hpp"
#include "stan/model/prob_grad_ad.hpp"
#include "nuts_diaggiven.hpp"
#include "lmc.hpp"
#include "t3.hpp"

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

	EXPORT double getValue(num n)
	{
		return ((stan::agrad::var*)&n)->val();
	}

	EXPORT num makeNum(double val)
	{
		stan::agrad::var v(val);
		return *(num*)&v;
	}
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

extern "C"
{
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


struct T3SamplerState
{
public:
	int _steps;
	double _globalTempMult;
	HMCSamplerState* _hmcs;
	InterpolatedFunctionPointerModel model;
	stan::mcmc::t3<boost::mt19937>* sampler;
	T3SamplerState(int steps, double globalTempMult, HMCSamplerState* hmcs)
		: model(), sampler(NULL), _steps(steps), _globalTempMult(globalTempMult),
		  _hmcs(hmcs) {}
	~T3SamplerState() { if (sampler) delete sampler; }
};

extern "C"
{

	EXPORT T3SamplerState* newSampler(int steps, double globalTempMult)
	{
		return new T3SamplerState(steps, globalTempMult, NULL);
	}

	// Instead of a fixed number of steps, use the average tree depth of a NUTS sampler
	EXPORT T3SamplerState* newSampler(HMCSamplerState* hmcs, double globalTempMult)
	{
		stan::mcmc::nuts_diaggiven<boost:mt19937>* casted = 
		dynamic_cast<stan::mcmc::nuts_diaggiven<boost:mt19937>*>(hmcs->sampler);
		if (casted == NULL)
			hmcError("Cannot use a non-NUTS sampler as the length oracle for a T3 sampler.");

		return new T3SamplerState(-1, globalTempMult, hmcs);
	}

	EXPORT void deleteSampler(T3SamplerState* s)
	{
		delete s;
	}

	EXPORT void setLogprobFunctions(T3SamplerState* s, LogProbFunction lpfn1, LogProbFunction lpfn2)
	{
		s->model.setLogprobFunctions(lpfn1, lpfn2);
	}

	EXPORT double nextSample(T3SamplerState* s, int numvals, double* vals,
							 int numOldIndices, int* oldVarIndices, int numNewIndices, int* newVarIndices)
	{
		// Set variable values, reset inverse masses
		if (s->model.lpfn1 == NULL || s->model.lpfn2 == NULL)
			hmcError("Cannot set variable values before log prob functions have been set.");
		std::vector<double> params_r(numvals);
		memcpy(&params_r[0], vals, numvals*sizeof(double));
		s->model.set_num_params_r(numvals);
		if (s->sampler == NULL)
		{
			std::vector<int> params_i;
			stan::mcmc::nuts_diaggiven<boost:mt19937>* casted = 
				dynamic_cast<stan::mcmc::nuts_diaggiven<boost:mt19937>*>(s->_hmcs->sampler);
			s->sampler = new stan::mcmc::t3<boost::mt19937>(model, params_r, params_i,
															s->_steps, s->_globalTempMult, casted);
		}
		else
		{
			sampler->set_params_r(params_r);
			sampler->reset_inv_masses(params_r.size());
		}

		// Set var indices
		std::vector<int> ovi(numOldIndices);
		std::vector<int> nvi(numNewIndices);
		memcpy(&ovi[0], oldVarIndices, numOldIndices*sizeof(int));
		memcpy(&nvi[0], newVarIndices, numNewIndices*sizeof(int));
		s->sampler->set_var_indices(ovi, nvi);

		// Now actually take the step
		stan::mcmc::sample samp = s->sampler->next();
		const std::vector<double>& newvals = samp->params_r();
		memcpy(vals, &newvals[0], numvals*sizeof(double));
		return samp.log_prob();	// This actually returns the kinetic energy difference.
	}

}



