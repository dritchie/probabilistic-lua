#include "cInterface.h"
#include "Framebuffer.h"


#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__ ((visibility ("default")))
#endif


typedef Framebuffer<INNERNUMTYPE> FRAMEBUFFER;


extern "C"
{

	EXPORT FRAMEBUFFER* FRAMEBUFFER_new(int width, int height, NUMTYPE clearVal)
	{
		return new FRAMEBUFFER(width, height, NUM_TO_INNERNUM(clearVal));
	}

	EXPORT FRAMEBUFFER* FRAMEBUFFER_newFromMaskImage(char* filename)
	{
		return FRAMEBUFFER::newFromMaskImage(filename);
	}

	EXPORT void FRAMEBUFFER_saveToPNGImage(FRAMEBUFFER* fb, char* filename)
	{
		fb->saveToPNGImage(filename);
	}

	EXPORT void FRAMEBUFFER_clear(FRAMEBUFFER* fb)
	{
		fb->clear();
	}

	EXPORT void FRAMEBUFFER_invert(FRAMEBUFFER* fb)
	{
		fb->invert();
	}

	EXPORT void FRAMEBUFFER_delete(FRAMEBUFFER* fb)
	{
		delete fb;
	}

	EXPORT void FRAMEBUFFER_distance(FRAMEBUFFER* fb1, FRAMEBUFFER* fb2)
	{
		return fb1->distanceFrom(fb2);
	}

	EXPORT void FRAMEBUFFER_renderCircle(FRAMEBUFFER* fb, NUMTYPE x, NUMTYPE y, NUMTYPE r,
		int doSmoothing, double fieldSmoothing, double minMaxSmoothing)
	{
		fb1->renderCircle(NUM_TO_INNERNUM(x), NUM_TO_INNERNUM(y), NUM_TO_INNERNUM(r),
			doSmoothing, fieldSmoothing, minMaxSmoothing);
	}

	EXPORT int FRAMEBUFFER_width(FRAMEBUFFER* fb)
	{
		fb1->getWidth();
	}

	EXPORT int FRAMEBUFFER_height(FRAMEBUFFER* fb)
	{
		fb1->getHeight();
	}

}