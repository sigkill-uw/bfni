ASSEMBLER=nasm

.PHONY: all clean

all: bfni

bfni: bfni.o
	ld -m elf_i386 -o bfni bfni.o

bfni.o: bfni.asm
	nasm -f elf -g -Wall bfni.asm

clean:
	rm bfni bfni.o
