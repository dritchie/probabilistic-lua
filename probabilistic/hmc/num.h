
typedef struct	
{
	void* impl;
} num;

typedef num(*LogProbFunction)(num*);

num makeNum(double val);

double getValue(num n);