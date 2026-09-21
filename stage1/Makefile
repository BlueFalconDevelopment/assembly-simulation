SRCS := $(wildcard *.asm)
BINS := $(patsubst %.asm,build/%,$(SRCS))

all: $(BINS)

build/%: %.asm | build
	nasm -f elf64 -g -F dwarf $< -o build/$*.o
	ld build/$*.o -o $@

build:
	mkdir -p build

clean:
	rm -rf build

.PHONY: all clean
