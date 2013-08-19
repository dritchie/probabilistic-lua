
CC=clang++
SO=librender.so

FREEIMAGE_HDIR=/opt/local/include
FREEIMAGE_LDIR=/opt/local/lib

CFLAGS=-I../probabilistic/hmc -I$(FREEIMAGE_HDIR) -I$(STAN_ROOT)/src
LDFLAGS=-L$(FREEIMAGE_LDIR) -L../probabilistic/hmc -lfreeimage -lhmc

CPP=\
	doubleImplementation.cpp \
	dualnumImplementation.cpp

OBJ=$(CPP:.cpp=.o)

all: $(SO)

clean:
	rm -f *.o *.so

$(SO): $(OBJ)
	$(CC) -shared $(LDFLAGS) $(OBJ) -o $@

%.o: %.cpp
	$(CC) -c -O3 $(CFLAGS) $*.cpp -o $@