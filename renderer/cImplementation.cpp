#include "cInterface.h"
#include "Framebuffer.h"


#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__ ((visibility ("default")))
#endif


typedef Framebuffer<INNERNUMTYPE> FramebufferT;

struct FRAMEBUFFER
{
	FramebufferT* innerfb;
};


extern "C"
{

	EXPORT FRAMEBUFFER* CAT(FRAMEBUFFER, _new)(int width, int height, NUMTYPE clearVal)
	{
		FRAMEBUFFER* fb = new FRAMEBUFFER;
		fb->innerfb = new FramebufferT(width, height, NUM_TO_INNERNUM(clearVal));
		return fb;
	}

	EXPORT FRAMEBUFFER* CAT(FRAMEBUFFER, _newFromMaskImage)(char* filename, NUMTYPE clearVal)
	{
		FRAMEBUFFER* fb = new FRAMEBUFFER;
		fb->innerfb = FramebufferT::newFromMaskImage(filename, NUM_TO_INNERNUM(clearVal));
		return fb;
	}

	EXPORT void CAT(FRAMEBUFFER, _saveToPNGImage)(FRAMEBUFFER* fb, char* filename)
	{
		fb->innerfb->saveToPNGImage(filename);
	}

	EXPORT void CAT(FRAMEBUFFER, _clear)(FRAMEBUFFER* fb)
	{
		fb->innerfb->clear();
	}

	EXPORT void CAT(FRAMEBUFFER, _invert)(FRAMEBUFFER* fb)
	{
		fb->innerfb->invert();
	}

	EXPORT void CAT(FRAMEBUFFER, _delete)(FRAMEBUFFER* fb)
	{
		delete fb->innerfb;
		delete fb;
	}

	EXPORT NUMTYPE CAT(FRAMEBUFFER, _distance)(FRAMEBUFFER* fb1, FRAMEBUFFER* fb2)
	{
		INNERNUMTYPE dist = fb1->innerfb->distanceFrom(fb2->innerfb);
		return INNERNUM_TO_NUM(dist);
	}

	EXPORT void CAT(FRAMEBUFFER, _renderCircle)(FRAMEBUFFER* fb, NUMTYPE x, NUMTYPE y, NUMTYPE r,
		int doSmoothing, double fieldSmoothing, double minMaxSmoothing)
	{
		fb->innerfb->renderCircle(NUM_TO_INNERNUM(x), NUM_TO_INNERNUM(y), NUM_TO_INNERNUM(r),
			doSmoothing, fieldSmoothing, minMaxSmoothing);
	}

	EXPORT int CAT(FRAMEBUFFER, _width)(FRAMEBUFFER* fb)
	{
		return fb->innerfb->getWidth();
	}

	EXPORT int CAT(FRAMEBUFFER, _height)(FRAMEBUFFER* fb)
	{
		return fb->innerfb->getHeight();
	}

}