/*
This file is included by terralib.includec and describes the Terra interface to
the HMC sampling library
*/

// The dual number type
struct vari;
typedef struct
{
	struct vari* impl_;
} num;

/* The sampler interface */

// Opaque type declaration for sampler state object
struct SamplerState;

// Creation/deletion of samplers
struct SamplerState* newSampler();
void deleteSampler(struct SamplerState* s);

// Setting the log probability function for a sampler
typedef num(*LogProbFunction)(num*);
void setLogprobFunction(struct SamplerState* s, LogProbFunction lpfn);

// Interacting with the sampler
// 'vals' holds the current variable values and will be overwritten.
int nextSample(struct SamplerState* s, double* vals);
void setVariableValues(struct SamplerState* s, int numvals, double* vals);
