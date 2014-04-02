ASSEMBLER=nasm

.PHONY: all clean test

all: bfni

bfni: bfni.o
	ld -m elf_i386 -o bfni bfni.o

bfni.o: bfni.asm
	nasm -f elf -Wall bfni.asm

test: bfni
	cat input.tst | ./bfni > output.asm
	nasm -f elf -g -Wall output.asm
	ld -m elf_i386 -o output output.o

clean:
	rm bfni bfni.o
