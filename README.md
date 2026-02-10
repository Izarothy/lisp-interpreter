# lisp-interpreter

Lisp-like arithmetic interpreter for Linux x86-64, written in NASM assembly and linked with `ld`.

## Features

- Syscall-only runtime (`read`, `write`, `exit`), no libc
- REPL loop (one expression per line)
- Operators: `add`, `sub`, `mul`, `div`
- Nested expressions and singleton numeric list form `(3)`
- Signed 64-bit arithmetic with overflow detection
- Division truncates toward zero (`idiv` semantics)
- Grouped decimal output with commas every 3 digits
- Deterministic I/O failure handling (no silent read/write failure)
- Buffered stdout for lower syscall overhead in non-interactive mode

## Grammar

- `expr := number | list`
- `list := '(' symbol expr+ ')' | '(' number ')'`
- `symbol := add | sub | mul | div`
- `number := '-'? [0-9]+`

## Operator Token Rules

Operator symbols must be exact tokens. After `add`/`sub`/`mul`/`div`, the next byte must be one of:

- whitespace (`space`, `tab`, `\n`, `\r`)
- `)`
- end-of-line

Examples rejected as malformed/unknown symbols:

- `(add1 2)`
- `(add-1 2)`
- `(mul0 2)`
- `(div2 2)`
- `(sub-5)`

## Semantics

- `add`: variadic, minimum 1 argument
- `mul`: variadic, minimum 1 argument
- `sub`: one argument => unary negation, otherwise left-fold subtraction
- `div`: minimum 2 arguments, left-fold signed division

## Streams

- Successful evaluation result lines are written to `stdout`.
- Interpreter error lines (`error: ...`) are written to `stderr`.

## Blank Lines

Blank/whitespace-only input lines are ignored (no output, no error).

## Errors

Interpreter errors are reported as `error: <reason>` where `<reason>` is:

- `unexpected token`
- `unmatched parenthesis`
- `missing arguments`
- `unknown symbol`
- `division by zero`
- `integer overflow`
- `line too long`

## I/O Failure Behavior

- Non-EINTR `read` failure from stdin is treated as fatal (not EOF).
- Write failures are not ignored.
- Fatal I/O paths emit `fatal: ...` to `stderr` when possible and exit non-zero.

Exit codes:

- `0`: normal EOF termination
- `1`: fatal stdin read failure
- `2`: fatal output failure

## Build

```bash
make
```

Default build settings are in `Makefile`:

- configurable tools: `NASM`, `LD`
- configurable flags: `NASMFLAGS`, `LDFLAGS`
- `LINKMODE=pie|static` (default `pie`)
- auto-detected `DYNAMIC_LINKER` for PIE (override if needed)
- hardened link defaults: `-z relro -z now -z noexecstack -z separate-code`
- explicit non-exec stack note via `.note.GNU-stack`

If `nasm` is not on your default `PATH`, prepend its location when invoking `make`.

## Run

```bash
make run
```

## Test

```bash
make test
```

Microbenchmark helper:

```bash
make bench
```

Tests validate:

- arithmetic semantics and overflow behavior
- malformed operator token rejection
- stdout/stderr separation
- blank-line behavior
- long-line recovery
- REPL continuation after errors
