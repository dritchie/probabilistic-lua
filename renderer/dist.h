#ifndef __RENDERER_DIST__H
#define __RENDERER_DIST__H

#include "num.h"

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__ ((visibility ("default")))
#endif

#define EXTERN extern "C" {
#ifdef __cplusplus
EXTERN
#endif

struct Framebufferdouble;
struct Framebuffernum;


EXPORT num Framebuffer_num_double_distance(struct Framebuffernum* fb, struct Framebufferdouble* fbtarget,
										   double nonZeroPixelWeight);

#ifdef __cplusplus
}
#endif

#endif