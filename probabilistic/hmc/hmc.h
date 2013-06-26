/*
This file is included by terralib.includec and describes the Terra interface to
the HMC sampling library
*/

// The dual number type
struct vari;
typedef struct
{
	vari* impl_;
} num;

/* The sampler interface */

// Opaque type declaration for sampler state object
struct SamplerState;

// Creation/deletion of samplers
SamplerState* newSampler();
void deleteSampler(SamplerState* s);

// Setting the log probability function for a sampler
typedef num(*LogProbFunction)(num*);
void setLogprobFunction(SamplerState* s, LogProbFunction lpfn);

// Interacting with the sampler
// 'vals' holds the current variable values and will be overwritten.
bool nextSample(SamplerState* s, double* vals);
void setVariableValues(SamplerState* s, int numvals, double* vals);
