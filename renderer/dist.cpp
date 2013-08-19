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
	EXPORT num Framebuffer_num_double_distance(Framebuffernum* fb1, Framebufferdouble* fb2)
	{
		stan::agrad::var dist = fb1->innerfb->distanceFrom(fb2->innerfb);
		return *((num*)(&dist));
	}

	EXPORT num Framebuffer_double_num_distance(Framebufferdouble* fb1, Framebuffernum* fb2)
	{
		return Framebuffer_num_double_distance(fb2, fb1);
	}
}