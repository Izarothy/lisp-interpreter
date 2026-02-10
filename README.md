# lisp-interpreter

Minimal Lisp-like arithmetic interpreter in x86-64 Linux assembly using NASM + `ld`.

## Features

- Linux x86-64 target, syscall-only (`read`, `write`, `exit`)
- REPL loop: reads one expression per line until EOF
- Supported operators: `add`, `sub`, `mul`, `div`
- Nested expressions
- Singleton list numbers: `(3)` evaluates to `3`
- Signed division using `idiv` (truncate toward zero)
- Error recovery: prints `error: <reason>` and continues to next line

## Grammar

- `expr := number | list`
- `list := '(' symbol expr+ ')' | '(' number ')'`
- `symbol := add | sub | mul | div`
- `number := '-'? [0-9]+`

## Semantics

- `add`: variadic, minimum 1 arg
- `mul`: variadic, minimum 1 arg
- `sub`: one arg => unary negate, otherwise left-fold subtraction
- `div`: minimum 2 args, left-fold signed division
- Division by zero errors
- Integer overflow errors (parse and arithmetic)

## Error Reasons

- `unexpected token`
- `unmatched parenthesis`
- `missing arguments`
- `unknown symbol`
- `division by zero`
- `integer overflow`

## Build

```bash
make
```

This runs:

```bash
nasm -f elf64 src/main.asm -o build/main.o && ld build/main.o -o lispasm
```

## Run

```bash
make run
```

Or:

```bash
./lispasm
```

## Test

```bash
make test
```

The runner uses `tests/cases.txt` and also checks that the REPL continues after an error line.

## Make Targets

- `all`
- `run`
- `test`
- `clean`

## Notes for this Windows + WSL environment

If `nasm` is not globally installed in WSL, you can provide it via `PATH`:

```bash
PATH="$HOME/.local/nasm-pkg/usr/bin:$PATH" make test
```
