NASM ?= nasm
LD ?= ld

NASMFLAGS ?= -f elf64 -Wall -Werror -Ox
LDFLAGS ?= -z relro -z now -z noexecstack -z separate-code

BUILD_DIR ?= build
SRC := src/main.asm
OBJ := $(BUILD_DIR)/main.o
BIN := lispasm

.PHONY: all clean run test bench

all: $(BIN)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(OBJ): $(SRC) | $(BUILD_DIR)
	$(NASM) $(NASMFLAGS) $< -o $@

$(BIN): $(OBJ)
	$(LD) -pie --no-dynamic-linker $(LDFLAGS) -o $@ $^

run: $(BIN)
	./$(BIN)

test: $(BIN)
	bash tests/test.sh

bench: $(BIN)
	bash tests/bench.sh

clean:
	rm -rf $(BUILD_DIR) $(BIN)