
CC=clang++
SO=librender.so

FREEIMAGE_HDIR=/opt/local/include
FREEIMAGE_LDIR=/opt/local/lib

CFLAGS=-I../probabilistic/hmc -I$(FREEIMAGE_HDIR)
LDFLAGS=-L$(FREEIMAGE_LDIR) -lfreeimage

CPP=\
	doubleImplementation.cpp \
	dualnumImplementation.cpp

OBJ=$(CPP:.cpp=.o)

all: $(SO)

clean:
	rm -f *.o *.so

clang++ -shared -O3 -I%s -I%s -I%s %s %s -o %s"

SO: $(OBJ)
	$(CC) -shared $(OBJ) -o $@

%.o: %.cpp
	$(CC) -O3 $(CFLAGS) $*.cpp -o $@