NASM ?= nasm
LD ?= ld
CC ?= cc

NASMFLAGS ?= -f elf64 -Wall -Werror -Ox
LDFLAGS ?= -z relro -z now -z noexecstack -z separate-code
LINKMODE ?= pie

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

CC_LOADER := $(shell p="$$( $(CC) -print-file-name=ld-linux-x86-64.so.2 2>/dev/null )"; [ "$$p" != "ld-linux-x86-64.so.2" ] && [ -e "$$p" ] && echo "$$p")
DYNAMIC_LINKER ?= $(firstword $(CC_LOADER) $(wildcard /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2 /usr/lib/ld-linux-x86-64.so.2 /lib/ld-musl-x86_64.so.1))

BUILD_DIR ?= build
SRC := src/main.asm
OBJ := $(BUILD_DIR)/main.o
BIN := lispasm

.PHONY: all run test bench clean

ifeq ($(LINKMODE),pie)
  ifeq ($(strip $(DYNAMIC_LINKER)),)
    $(error No dynamic loader path detected for PIE. Set DYNAMIC_LINKER=/path/to/loader or use LINKMODE=static)
  endif
  LINKFLAGS := -pie -dynamic-linker $(DYNAMIC_LINKER)
else ifeq ($(LINKMODE),static)
  LINKFLAGS := -static
else
  $(error Unsupported LINKMODE='$(LINKMODE)'; expected pie or static)
endif

all: $(BIN)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(OBJ): $(SRC) | $(BUILD_DIR)
	$(NASM) $(NASMFLAGS) $< -o $@

$(BIN): $(OBJ)
	$(LD) $(LINKFLAGS) $(LDFLAGS) -o $@ $^

run: $(BIN)
	./$(BIN)

test: $(BIN)
	bash tests/run_tests.sh

bench: $(BIN)
	bash tests/bench.sh ./$(BIN)

clean:
	rm -rf $(BUILD_DIR) $(BIN)
