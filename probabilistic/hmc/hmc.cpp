/*
This file implements the HMC sampling library and is compiled into a shared library.
*/

#include "stan/agrad/agrad.hpp"
#include "stan/model/prob_grad_ad.hpp"
#include "nuts_diaggiven.hpp"
#include "adaptive_hmc_diaggiven.hpp"
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
	NUTS = 1,
	HMC = 2
};


// Packages together a stan sampler and the model it samples from
struct HMC_SamplerState
{
public:
	HMCSamplerType type;
	FunctionPoinderModel model;
	stan::mcmc::ppl_hmc<boost::mt19937>* sampler;
	int _steps;
	double _partialMomentumAlpha;
	HMC_SamplerState(HMCSamplerType t, int steps, double partialMomentumAlpha)
		: type(t), model(), sampler(NULL), _steps(steps), _partialMomentumAlpha(partialMomentumAlpha) {}
	~HMC_SamplerState()
	{
		if (sampler) delete sampler;
	}
	void init(const std::vector<double>& params_r)
	{
		if (sampler == NULL)
		{
			std::vector<int> params_i;
			if (type == Langevin)
				sampler = new stan::mcmc::lmc<>(model, params_r, params_i, _partialMomentumAlpha);
			else if (type == NUTS)
				sampler = new stan::mcmc::nuts_diaggiven<>(model, params_r, params_i);
			else if (type == HMC)
				sampler = new stan::mcmc::adaptive_hmc_diaggiven<>(model, params_r, params_i, _steps);
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
	EXPORT HMC_SamplerState* HMC_newSampler(int type, int steps, double partialMomentumAlpha)
	{
		HMCSamplerType stype = (HMCSamplerType)type;
		return new HMC_SamplerState(stype, steps, partialMomentumAlpha);
	}

	EXPORT void HMC_deleteSampler(HMC_SamplerState* s)
	{
		delete s;
	}

	EXPORT void HMC_setLogprobFunction(HMC_SamplerState* s, LogProbFunction lpfn)
	{
		s->model.setLogprobFunction(lpfn);
	}

	EXPORT int HMC_nextSample(HMC_SamplerState* s, double* vals)
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

	EXPORT void HMC_setVariableValues(HMC_SamplerState* s, int numvals, double* vals)
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

	EXPORT void HMC_setVariableInvMasses(HMC_SamplerState* s, double* invmasses)
	{
		std::vector<double> imasses(s->model.num_params_r());
		memcpy(&imasses[0], invmasses, s->model.num_params_r()*sizeof(double));
		s->sampler->set_inv_masses(imasses);
	}

	EXPORT void HMC_recomputeLogProb(HMC_SamplerState* s)
	{
		s->sampler->recompute_log_prob();
	}
}


///////////////////////////////////////////////////////////////////////
//							  T3 Sampler							 //
///////////////////////////////////////////////////////////////////////


struct T3_SamplerState
{
public:
	int _steps;
	double _stepSize;
	double _globalTempMult;
	HMC_SamplerState* _hmcs;
	InterpolatedFunctionPointerModel model;
	stan::mcmc::t3<boost::mt19937>* sampler;
	T3_SamplerState(int steps, double stepSize, double globalTempMult, HMC_SamplerState* hmcs)
		: model(), sampler(NULL), _steps(steps), _stepSize(stepSize), _globalTempMult(globalTempMult),
		  _hmcs(hmcs) {}
	~T3_SamplerState() { if (sampler) delete sampler; }
};

extern "C"
{
	EXPORT T3_SamplerState* T3_newSampler(int steps, double stepSize, double globalTempMult, HMC_SamplerState* oracle)
	{
		return new T3_SamplerState(steps, stepSize, globalTempMult, oracle);
	}

	EXPORT void T3_deleteSampler(T3_SamplerState* s)
	{
		delete s;
	}

	EXPORT void T3_setLogprobFunctions(T3_SamplerState* s, LogProbFunction lpfn1, LogProbFunction lpfn2)
	{
		s->model.setLogprobFunctions(lpfn1, lpfn2);
	}

	EXPORT double T3_nextSample(T3_SamplerState* s, int numvals, double* vals,
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
			bool doAdapt = s->_stepSize <= 0.0;
			s->sampler = new stan::mcmc::t3<boost::mt19937>(s->model, params_r, params_i,
															s->_steps, s->_globalTempMult, s->sampler,
															s->_stepSize, 0.0, doAdapt);
		}
		else
		{
			s->sampler->set_params_r(params_r);
			s->sampler->reset_inv_masses(params_r.size());
		}

		// Set var indices
		std::vector<int> ovi(numOldIndices);
		std::vector<int> nvi(numNewIndices);
		memcpy(&ovi[0], oldVarIndices, numOldIndices*sizeof(int));
		memcpy(&nvi[0], newVarIndices, numNewIndices*sizeof(int));
		s->sampler->set_var_indices(ovi, nvi);

		// Now actually take the step
		stan::mcmc::sample samp = s->sampler->next();
		const std::vector<double>& newvals = samp.params_r();
		memcpy(vals, &newvals[0], numvals*sizeof(double));
		return samp.log_prob();	// This actually returns the kinetic energy difference.
	}

}



