# Stage 10: one folder per step (NN_name/main.asm plus its modules),
# built to build/NN_name. NASM looks for a step's modules in its own
# folder (-i), and for maps/ here, where make runs.
STEPS := $(patsubst %/main.asm,%,$(wildcard [0-9][0-9]_*/main.asm))
BINS := $(addprefix build/,$(STEPS))
SDL_LIBS := $(shell pkg-config --libs sdl2)
MAPS := $(wildcard maps/*)

all: $(BINS)

.SECONDEXPANSION:
build/%: $$(wildcard %/*.asm) $(MAPS) | build
	nasm -f elf64 -g -F dwarf -i $*/ $*/main.asm -o build/$*.o
	gcc -no-pie build/$*.o -o $@ $(SDL_LIBS)

build:
	mkdir -p build

clean:
	rm -rf build

.PHONY: all clean
