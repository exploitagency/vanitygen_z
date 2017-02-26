LIBS=-lpcre -lcrypto -lm -lpthread
CFLAGS=-ggdb -O3 -Wall
OBJS=vanitygen_z.o pattern_z.o util_z.o oclvanitygen_z.o oclengine_z.o
PROGS=vanitygen_z oclvanitygen_z keyconv_z

PLATFORM=$(shell uname -s)
ifeq ($(PLATFORM),Darwin)
OPENCL_LIBS=-framework OpenCL
else
OPENCL_LIBS=-lOpenCL
endif


most: vanitygen_z keyconv_z

all: $(PROGS)

vanitygen_z: vanitygen_z.o pattern_z.o util_z.o
	$(CC) $^ -o $@ $(CFLAGS) $(LIBS)

oclvanitygen_z: oclvanitygen_z.o oclengine_z.o pattern_z.o util_z.o
	$(CC) $^ -o $@ $(CFLAGS) $(LIBS) $(OPENCL_LIBS)

keyconv_z: keyconv_z.o util_z.o
	$(CC) $^ -o $@ $(CFLAGS) $(LIBS)

clean:
	rm -f $(OBJS) $(PROGS) $(TESTS) *.oclbin
