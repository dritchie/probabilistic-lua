#ifndef __RENDERER_C_INTERFACE__H
#define __RENDERER_C_INTERFACE__H

// Macros for constructing function/type names
#define CAT_I(a,b) a##b
#define CAT(a,b) CAT_I(a, b)

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__ ((visibility ("default")))
#endif

#define EXTERN extern "C" {
#ifdef __cplusplus
EXTERN
#endif

// Declare the existence of the Framebuffer struct
#define FRAMEBUFFER CAT(Framebuffer, NUMTYPE)
#define FRAMEBUFFER_T struct FRAMEBUFFER
FRAMEBUFFER_T;

// Publicly visible functions
EXPORT FRAMEBUFFER_T* CAT(FRAMEBUFFER, _new)(int width, int height, NUMTYPE clearVal);
EXPORT FRAMEBUFFER_T* CAT(FRAMEBUFFER, _newFromMaskImage)(char* filename, NUMTYPE clearVal);
EXPORT void CAT(FRAMEBUFFER, _saveToPNGImage)(FRAMEBUFFER_T* fb, char* filename);
EXPORT void CAT(FRAMEBUFFER, _saveGradientImageToPNGImage)(FRAMEBUFFER_T* fb, char* filename);
EXPORT void CAT(FRAMEBUFFER, _clear)(FRAMEBUFFER_T* fb);
EXPORT void CAT(FRAMEBUFFER, _invert)(FRAMEBUFFER_T* fb);
EXPORT void CAT(FRAMEBUFFER, _delete)(FRAMEBUFFER_T* fb);
EXPORT NUMTYPE CAT(FRAMEBUFFER, _distance)(FRAMEBUFFER_T* fb, FRAMEBUFFER_T* fbtarget, double nonZeroPixelWeight);
EXPORT void CAT(FRAMEBUFFER, _renderCircle)(FRAMEBUFFER_T* fb, NUMTYPE x, NUMTYPE y, NUMTYPE r,
	int doSmoothing, double tightFieldSmoothing, double looseFieldSmoothing, double fieldBlend, double minMaxSmoothing);
EXPORT int CAT(FRAMEBUFFER, _width)(FRAMEBUFFER_T* fb);
EXPORT int CAT(FRAMEBUFFER, _height)(FRAMEBUFFER_T* fb);
EXPORT NUMTYPE CAT(FRAMEBUFFER, _getPixelValue)(FRAMEBUFFER_T* fb, int x, int y);

#ifdef __cplusplus
}
#endif

#endif