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
FRAMEBUFFER_T* FRAMEBUFFER_new(int width, int height, NUMTYPE clearVal);
FRAMEBUFFER_T* FRAMEBUFFER_newFromMaskImage(char* filename);
void FRAMEBUFFER_saveToPNGImage(FRAMEBUFFER_T* fb, char* filename);
void FRAMEBUFFER_clear(FRAMEBUFFER_T* fb);
void FRAMEBUFFER_invert(FRAMEBUFFER_T* fb);
void FRAMEBUFFER_delete(FRAMEBUFFER_T* fb);
void FRAMEBUFFER_distance(FRAMEBUFFER_T* fb1, FRAMEBUFFER_T* fb2);
void FRAMEBUFFER_renderCircle(FRAMEBUFFER_T* fb, NUMTYPE x, NUMTYPE y, NUMTYPE r,
	int doSmoothing, double fieldSmoothing, double minMaxSmoothing);
int FRAMEBUFFER_width(FRAMEBUFFER_T* fb);
int FRAMEBUFFER_height(FRAMEBUFFER_T* fb);


#endif