#ifndef __RENDERER_C_INTERFACE__H
#define __RENDERER_C_INTERFACE__H

// Macros for constructing function/type names
#define CAT_I(a,b) a##b
#define CAT(a,b) CAT_I(a, b)


// Declare the existence of the Framebuffer struct
#define FRAMEBUFFER CAT(Framebuffer, NUMTYPE)
#define FRAMEBUFFER_T struct FRAMEBUFFER
FRAMEBUFFER_T;


// Publicly visible functions
FRAMEBUFFER_T* CAT(FRAMEBUFFER, _new)(int width, int height, NUMTYPE clearVal);
FRAMEBUFFER_T* CAT(FRAMEBUFFER, _newFromMaskImage)(char* filename, NUMTYPE clearVal);
void CAT(FRAMEBUFFER, _saveToPNGImage)(FRAMEBUFFER_T* fb, char* filename);
void CAT(FRAMEBUFFER, _clear)(FRAMEBUFFER_T* fb);
void CAT(FRAMEBUFFER, _invert)(FRAMEBUFFER_T* fb);
void CAT(FRAMEBUFFER, _delete)(FRAMEBUFFER_T* fb);
NUMTYPE CAT(FRAMEBUFFER, _distance)(FRAMEBUFFER_T* fb1, FRAMEBUFFER_T* fb2);
void CAT(FRAMEBUFFER, _renderCircle)(FRAMEBUFFER_T* fb, NUMTYPE x, NUMTYPE y, NUMTYPE r,
	int doSmoothing, double fieldSmoothing, double minMaxSmoothing);
int CAT(FRAMEBUFFER, _width)(FRAMEBUFFER_T* fb);
int CAT(FRAMEBUFFER, _height)(FRAMEBUFFER_T* fb);


#endif