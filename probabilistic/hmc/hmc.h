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
		NUTS
	};
*/
struct HMCSamplerState;
struct HMCSamplerState* newSampler(int type);
void deleteSampler(struct HMCSamplerState* s);
void setLogprobFunction(struct HMCSamplerState* s, LogProbFunction lpfn);
int nextSample(struct HMCSamplerState* s, double* vals);
void setVariableValues(struct HMCSamplerState* s, int numvals, double* vals);
void setVariableInvMasses(struct HMCSamplerState* s, double* invmasses);
void recomputeLogProb(struct HMCSamplerState* s);


/* Interface to the T3 sampler */
struct T3SamplerState;
struct T3SamplerState* newSampler(int steps, double globalTempMult);
// Instead of a fixed number of steps, use the average tree depth of a NUTS sampler
struct T3SamplerState* newSampler(struct HMCSamplerState* hmcs, double globalTempMult);
void deleteSampler(struct T3SamplerState* s);
void setLogprobFunctions(struct T3SamplerState* s, LogProbFunction lpfn1, LogProbFunction lpfn2);
// Returns the kinetic energy difference (necessary for acceptance criterion)
double nextSample(struct T3SamplerState* s, int numvals, double* vals,
				  int numOldIndices, int* oldVarIndices, int numNewIndices, int* newVarIndices);