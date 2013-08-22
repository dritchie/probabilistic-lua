#ifndef __RENDERER_EXTRA__H
#define __RENDERER_EXTRA__H

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


EXPORT void Framebuffer_gradientImage(struct Framebuffernum* src, struct Framebufferdouble* dst, num target);


#ifdef __cplusplus
}
#endif

#endif