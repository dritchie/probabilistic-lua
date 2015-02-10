#include "dist.h"
#include "var.h"
#include "Framebuffer.h"

struct Framebuffernum
{
	Framebuffer<stan::agrad::var>* innerfb;
};

struct Framebufferdouble
{
	Framebuffer<double>* innerfb;
};

extern "C"
{
	EXPORT num Framebuffer_num_double_distance(Framebuffernum* fb, Framebufferdouble* fbtarget,
		double zeroPixelWeight)
	{
		stan::agrad::var dist = fb->innerfb->distanceFrom(fbtarget->innerfb, zeroPixelWeight);
		return *((num*)(&dist));
	}
}