/*
This file is included by terralib.includec and describes the Terra interface to
the HMC sampling library
*/

// The dual number type
#include "num.h"

// C interfaces to dual number arithmetic
#include "adMath.h"

/* Interface to HMC samplers
   These are the possible types:
	enum HMCSamplerType
	{
		Langevin = 0,
		NUTS = 1,
		HMC = 2,
	};
*/
struct HMC_SamplerState;
struct HMC_SamplerState* HMC_newSampler(int type, int steps, double partialMomentumAlpha);
void HMC_deleteSampler(struct HMC_SamplerState* s);
void HMC_setLogprobFunction(struct HMC_SamplerState* s, LogProbFunction lpfn);
int HMC_nextSample(struct HMC_SamplerState* s, double* vals);
void HMC_setVariableValues(struct HMC_SamplerState* s, int numvals, double* vals);
void HMC_setVariableInvMasses(struct HMC_SamplerState* s, double* invmasses);
void HMC_recomputeLogProb(struct HMC_SamplerState* s);


/* Interface to the T3 sampler */
struct T3_SamplerState;
// 'oracle' is another sampler we can use to get e.g. step size info.
struct T3_SamplerState* T3_newSampler(int steps, double stepSize, double globalTempMult, struct HMC_SamplerState* oracle);
void T3_deleteSampler(struct T3_SamplerState* s);
void T3_setLogprobFunctions(struct T3_SamplerState* s, LogProbFunction lpfn1, LogProbFunction lpfn2);
// Returns the kinetic energy difference (necessary for acceptance criterion)
double T3_nextSample(struct T3_SamplerState* s, int numvals, double* vals,
				  int numOldIndices, int* oldVarIndices, int numNewIndices, int* newVarIndices);