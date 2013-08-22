#ifndef __LIBHMC_NUM_H__
#define __LIBHMC_NUM_H__

typedef struct	
{
	void* impl;
} num;

typedef num(*GradLogProbFunction)(num*);
typedef double(*LogProbFunction)(double*);

num makeNum(double val);

double getValue(num n);

void gradient(num dep, int numindeps, num* indeps, double* grad);

#endif