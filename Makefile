all:
	mkdir -p build
	nasm -f elf64 src/main.asm -o build/main.o && ld build/main.o -o lispasm

run: all
	./lispasm

test: all
	./tests/run_tests.sh

clean:
	rm -rf build lispasm
