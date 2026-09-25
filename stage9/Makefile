SRCS := $(wildcard *.asm)
BINS := $(patsubst %.asm,build/%,$(SRCS))
SDL_LIBS := $(shell pkg-config --libs sdl2)
MAPS := $(wildcard maps/*)          # 9.01: the map's include and data

all: $(BINS)

build/%: %.asm $(MAPS) | build
	nasm -f elf64 -g -F dwarf $< -o build/$*.o
	gcc -no-pie build/$*.o -o $@ $(SDL_LIBS)

build:
	mkdir -p build

clean:
	rm -rf build

.PHONY: all clean
