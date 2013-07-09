
typedef struct	
{
	void* impl;
} num;

num makeNum(double val);

double getValue(num n);