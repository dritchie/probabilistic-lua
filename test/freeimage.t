local fi = terralib.includec("/opt/local/include/FreeImage.h")
terralib.linklibrary("/opt/local/lib/libfreeimage.dylib")

return fi