#include "num.h"
#include "var.h"

#define NUMTYPE num
#define INNERNUMTYPE stan::agrad::var

#define NUM_TO_INNERNUM(n) (*((stan::agrad::var*)&n))
#define INNERNUM_TO_NUM(n) (*((num*)&n))

#include "cImplementation.cpp"

template <>
int Framebuffer<stan::agrad::var>::toInt(stan::agrad::var v)
{
	return (int)(v.val());
}