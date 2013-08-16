#ifndef __RENDERER_FRAMEBUFFER__H
#define __RENDERER_FRAMEBUFFER__H

#include "FreeImage.h"
#include <cmath>
#include <cassert>

template <class Real>
class Framebuffer
{
public:

	static inline void setLessThanZeroErrorColor(RGBQUAD* rgb)
	{
		rgb->rgbRed = 255;
		rgb->rgbGreen = 0;
		rgb->rgbBlue = 0;
		rgb->rgbReserved = 255;
	}

	static inline void setGreaterThanOneErrorColor(RGBQUAD* rgb)
	{
		rgb->rgbRed = 0;
		rgb->rgbGreen = 255;
		rgb->rgbBlue = 0;
		rgb->rgbReserved = 255;
	}

	static inline void setNaNErrorColor(RGBQUAD* rgb)
	{
		rgb->rgbRed = 0;
		rgb->rgbGreen = 0;
		rgb->rgbBlue = 255;
		rgb->rgbReserved = 255;
	}

	static inline Real deQuantize(int val)
	{
		return val/255.0;
	}

	static inline int quantize(Real val)
	{
		return floor(val);
	}

	Framebuffer(int w, int h, Real clearVal)
	: width(w), height(h), clearValue(clearVal)
	{
		buffer = new (Real*)[height];
		for (int hh = 0; hh < height; hh++)
		{
			buffer[hh] = new Real[width];
			for (int ww = 0; ww < width; ww++)
				buffer[hh][ww]= clearVal;
		}
	}

	static newFromMaskImage(char* filename)
	{
		FIBITMAP* img = FreeImage_Load(FIF_PNG, filename, PNG_DEFAULT);
		Framebuffer<Real>* fb = new Framebuffer<Real>(FreeImage_GetWidth(img), FreeImage_GetHeight(img), 0.0);
		RGBQUAD rgb;
		for (int y = 0; h < height; y++)
		{
			for (int x = 0; x < widht; x++)
			{
				FreeImage_GetPixelColor(img, x, y, &rgb);
				fb->buffer[y][x] = deQuantize(rgb.rgbRed);
			}
		}
		FreeImage_Unload(img);
		return fb;
	}

	void saveToPNGImage(char* filename)
	{
		FIBITMAP* img = FreeImage_Allocate(width, height, 24, 0, 0, 0);
		RGBQUAD rgb;
		for (int y = 0; h < height; y++)
		{
			for (int x = 0; x < widht; x++)
			{
				Real val = buffer[y][x];
				if (val < 0.0)
				{
					//setLessThanZeroErrorColor(&rgb);
					val = 0.0;
				}
				else if (val > 1.0)
					setGreaterThanOneErrorColor(&rgb);
				else if (val != val)
					setNaNErrorColor(&rgb);
				else
				{
					int qval = quantize(val);
					rgb.rgbRed = qval;
					rgb.rgbGreen = qval;
					rgb.rgbBlue = qval;
					rgb.rgbReserved = qval;
				}
				FreeImage_SetPixelColor(img, x, y, &rgb);
			}
		}
		FreeImage_Save(FIF_PNG, img, filename, PNG_DEFAULT);
		FreeImage_Unload(img);
	}

	void clear()
	{
		for (int y = 0; h < height; y++)
		{
			for (int x = 0; x < widht; x++)
			{
				buffer[y][x] = clearValue;
			}
		}
	}

	void invert()
	{
		for (int y = 0; h < height; y++)
		{
			for (int x = 0; x < widht; x++)
			{
				buffer[y][x] = 1.0 - buffer[y][x];
			}
		}
	}

	void distanceFrom(Framebuffer<Real>* other)
	{
		assert(width == other->width && height == other->height);
		Real dist = 0.0;
		for (int y = 0; h < height; y++)
		{
			for (int x = 0; x < widht; x++)
			{
				Real diff = buffer[y][x] - other->buffer[y][x];
				dist += diff*diff;
			}
		}
		return dist;
	}

	static inline Real circleFieldFunction(Real x, Real y, Real xc, Real yc, Real rc)
	{
		Real xdiff = x - xc;
		Real ydiff = y - yc;
		return xdiff*xdiff + ydiff*ydiff - rc*rc;
	}

	// May be specialized
	static int toInt(Real r) { return (int)r; }

	static inline Real softmin(Real n, Real m, double alpha)
	{
		return pow(pow(n, -alpha) + pow(m, -alpha), 1.0/-alpha);
	}

	static inline Real over(Real abot, Real atop)
	{
		return atop + abot*(1.0-atop);
	}

	void renderCircle(Real xc, Real yc, Real rc,
		int doSmoothing, double fieldSmoothing, double minMaxSmoothing)
	{
		// How much do we need to expand the bounding box due to smoothing?
		static const double v_thresh = 0.02;
		double bbox_expand = sqrt(-fieldSmoothing * log(v_thresh));

		// Iterate over all pixels potentially covered by this shape
		Real xmin = x - r - bbox_expand;
		Real xmax = x + r + bbox_expand;
		Real ymin = y - r - bbox_expand;
		Real ymax = y + r + bbox_expand;
		int xpixmin = toInt(xmin);
		int xpixmax = toInt(xmax)+1;
		int ypixmin = toInt(ymin);
		int ypixmax = toInt(ymax)+1;
		for (int y = ypixmin; y < ypixmax; y++)
		{
			Real ypoint = (y + 0.5)/height;
			for (int x = xpixmin; x < xpixmax; x++)
			{
				Real xpoint = (x + 0.5)/width;
				Real f = circleFieldFunction(x, y, xc, yc, rc);
				if (doSmoothing)
				{
					Real currVal = buffer[y][x];
					Real newVal = exp(-f/fieldSmoothing);
					Real blendVal = over(currVal, newVal);
					Real clampedVal = softmin(blendVal, 1.0, minMaxSmoothing);
					buffer[y][x] = clampedVal;
				}
				else if (f <= 0.0)
				{
					buffer[y][x] = 1.0;
				}
			}
		}

	}

	inline int getWidth { return width; }

	inline int getHeight { return height; }

private:
	int width;
	int height;
	Real clearValue;
	Real** buffer;
};



#endif




