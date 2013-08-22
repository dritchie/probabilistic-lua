#include "num.h"
#include "var.h"
#include <string.h>

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
template<>
double Framebuffer<stan::agrad::var>::value(stan::agrad::var r) { return r.val(); }

// This operation effectively destroys the values in this Framebuffer, because
// grad() recovers memory once completed.
template<>
void Framebuffer<stan::agrad::var>::renderGradientImage(Framebuffer<double>* dst, stan::agrad::var target)
{
	std::vector<stan::agrad::var> indepVars;
	std::vector<double> gradients;

	indepVars.resize(width*height);
	for (int y = 0; y < height; y++) for (int x = 0; x < height; x++)
		indepVars[y*width + x] = buffer[y][x];
	target.grad(indepVars, gradients);

	for (int y = 0; y < height; y++) for (int x = 0; x < height; x++)
	{
		//printf("%g\n", gradients[y*width + x]);
		dst->buffer[y][x] = gradients[y*width + x];
	}
}

// C interface version of the above
struct Framebufferdouble
{
	Framebuffer<double>* innerfb;
};
extern "C" EXPORT void Framebuffer_gradientImage(Framebuffernum* src, Framebufferdouble* dst, num target)
{
	stan::agrad::var targetVar = NUM_TO_INNERNUM(target);
	src->innerfb->renderGradientImage(dst->innerfb, targetVar);
}