NASM ?= nasm
LD ?= ld

NASMFLAGS ?= -f elf64 -Wall -Werror -Ox
LDFLAGS ?= -z relro -z now -z noexecstack -z separate-code

# Probe NASM warning flags across versions. Some NASM releases support
# -w-unknown-warning while others don't; some require explicit suppression
# for reloc-rel-dword under -Werror.
NASM_RELOC_WARN_FLAGS := $(shell \
	if command -v "$(NASM)" >/dev/null 2>&1; then \
		d="$$(mktemp -d 2>/dev/null || mktemp -d -t nasmprobe)"; \
		asm="$$d/probe.asm"; \
		obj="$$d/probe.o"; \
		printf 'bits 64\nsection .text\nnop\n' > "$$asm"; \
		if "$(NASM)" -f elf64 -Wall -Werror -w-unknown-warning -w-reloc-rel-dword "$$asm" -o "$$obj" >/dev/null 2>&1; then \
			echo '-w-unknown-warning -w-reloc-rel-dword'; \
		elif "$(NASM)" -f elf64 -Wall -Werror -w-reloc-rel-dword "$$asm" -o "$$obj" >/dev/null 2>&1; then \
			echo '-w-reloc-rel-dword'; \
		fi; \
		rm -rf "$$d"; \
	fi)
NASMFLAGS += $(NASM_RELOC_WARN_FLAGS)

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
