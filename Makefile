NASM ?= nasm
LD ?= ld

NASMFLAGS ?= -f elf64 -Wall -Werror -Ox
LDFLAGS ?= -z relro -z now -z noexecstack -z separate-code

BUILD_DIR ?= build
SRC := src/main.asm
OBJ := $(BUILD_DIR)/main.o
BIN := lispasm

.PHONY: all clean run test bench bench-compare

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

bench-compare: $(BIN)
	@if [ -z "$(BASELINE)" ]; then \
		echo "usage: make bench-compare BASELINE=/path/to/old/lispasm"; \
		exit 1; \
	fi
	bash tests/bench_compare.sh "$(BASELINE)" "./$(BIN)"

clean:
	rm -rf $(BUILD_DIR) $(BIN)
