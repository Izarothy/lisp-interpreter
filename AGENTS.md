# AGENTS.md — lispasm (NASM, Linux x86-64) Zen3-tuned, max-perf + clean history

Primary objective: MINIMIZE wall time of:
./lispasm < suite.txt > /dev/null 2> /dev/null

Target machine: AMD Ryzen 5 5600 (Zen 3), AVX2/BMI1/BMI2 available.
Environment: under a hypervisor (Microsoft / Hyper-V). Bench scripts must use repeated runs + median.

Secondary objectives: (1) pass suite.txt exactly, (2) high-quality, auditable assembly under heavy optimization, (3) maintain a clean, incremental git history.

If suite.txt conflicts with this document, match suite.txt.

---

## FEATURE SET (UPDATED)

- Syscall-only runtime: read/write/exit. No libc.
- One expression per input line (REPL). Blank/whitespace-only line => no output, no error.
- Operators: add, sub, mul, div
- Nested expressions
- Singleton numeric list form: (3) => 3
- Signed 64-bit arithmetic
- Overflow detection on parse and operations -> error: integer overflow
- Division truncates toward zero (idiv semantics)
- Errors go to stderr: "error: <reason>\n"
- Success goes to stdout: "<int>\n"

Removed:

- No grouped decimal output (no commas). Print plain base-10.
- No elaborate deterministic I/O failure handling. Do not implement verbose fatal paths / extra syscalls to explain broken IO.
  You may handle EINTR/partial writes for correctness, but do not build a “diagnostic subsystem”.

---

## GRAMMAR / TOKEN RULES

expr := number | list
list := '(' symbol expr+ ')' | '(' number ')'
symbol := add | sub | mul | div
number := '-'? [0-9]+

Operator token boundary rule:
After add/sub/mul/div, the next byte must be whitespace, ')' or end-of-line; otherwise => unknown symbol.
Examples that must be rejected as unknown symbol:
(add1 2) (add-1 2) (mul0 2) (div2 2) (sub-5) (add+1 2) (add_1 2) (add.1 2) (add$1 2)

Semantics:

- add: variadic, min 1 arg
- mul: variadic, min 1 arg
- sub: 1 arg => unary negation (overflow on INT64_MIN), else left-fold subtraction
- div: min 2 args, left-fold signed division; detect division by zero; detect INT64_MIN / -1 overflow

Errors (exact reasons, as used by suite.txt):

- unexpected token
- unmatched parenthesis
- missing arguments
- unknown symbol
- division by zero
- integer overflow
- line too long

---

## PERFORMANCE MANDATES (HARD)

You are optimizing the redirected suite-run command above. That means parse/eval dominates; output cost mostly disappears.
Still, correctness validation must be real (not a bench-only fast path).

1. Syscalls:

- Minimize syscalls aggressively.
- Read stdin in large chunks (e.g. 64 KiB or larger).
- Do NOT write per token or per line in non-interactive mode. Buffer stdout and flush at EOF (or when full).
- Stderr: buffer if convenient; but don’t spam syscalls. Most suite runs redirect stderr anyway.

2. Parsing:

- Single-pass over the input buffer. No “split into lines then parse again”, no copying into a second buffer for parsing.
- Implement a “discard until newline” mode for line-too-long recovery without rescanning old bytes.
- Design for branch predictability: fast path for typical chars (space, '(', ')', digit, '-', letter).

3. Hot-path assembly discipline:

- No push/pop in the hot parse/eval loop.
- Keep state in registers with a documented register allocation block comment.
- Error paths must be cold and out-of-line; hot path should fall through.
- Avoid call/ret in the hottest region unless it reduces total work and you measure it. Prefer local labels/jumps.
- No LOOP instruction.
- Use 32-bit zero idioms: xor eax,eax / xor edi,edi etc. Avoid xor r64,r64 unless justified by measurement.
- Avoid partial-register hazards (don’t write al/ah/etc then use rax without care).
- Align hot loops (e.g. 16-byte alignment) and keep hot code compact (I-cache matters on Zen3 too).

4. Optional but encouraged: vectorized scanning on Zen3

- Implement two scanner variants: scalar baseline + AVX2 fast scanner for skipping whitespace/newlines and finding interesting chars.
- Runtime dispatch at startup via CPUID + XGETBV (OSXSAVE + YMM enabled) to select AVX2 safely.
- Keep only these two variants to avoid I-cache bloat.
- If AVX is used in a region that returns to SSE code, use vzeroupper at the boundary.

Syscall ABI:

- syscall clobbers rcx and r11. Never keep live values there across syscalls.

---

## GIT HISTORY (HARD REQUIREMENT)

Maintain a full, readable git history. Do NOT squash or rewrite history.

Rules:

- Initialize git immediately.
- Commit in small, meaningful steps with messages that reflect what changed.
- Every commit must build. Prefer: make test passes before committing; if not possible, mark commit clearly as WIP and keep it rare.
- For any performance change: include bench numbers in the commit message body (before/after median) from make bench.
- Keep history linear (no rebases that rewrite).
- Do not vendor huge blobs or generated artifacts.

Suggested milestone commits:

1. scaffold: Makefile + directory layout + empty asm skeleton that exits 0
2. test harness parsing suite.txt + failing “not implemented” baseline
3. parser/evaluator correct enough to pass suite
4. fast I/O buffering + single-pass read/parse structure
5. overflow correctness hardening (edge cases)
6. Zen3 tuning passes (hot loop cleanup, branch layout, AVX2 scanner if beneficial)

---

## BUILD / TEST / BENCH

Provide Makefile targets:

- all (default): build ./lispasm
- clean
- run: run ./lispasm
- test: run tests/test.sh
- bench: run tests/bench.sh

tests/test.sh:

- Parses suite.txt lines:
  - either "INPUT" or "INPUT => EXPECTED"
- Runs ./lispasm and validates stdout/stderr exactly against the expectations extracted from suite.txt.

tests/bench.sh:

- Benchmarks the EXACT metric command:
  ./lispasm < suite.txt > /dev/null 2> /dev/null
- Must do:
  - 1 validation run with real output comparison (to prevent bench-only cheating)
  - warmup runs
  - timed runs with median reported (and min/avg if easy)
- If taskset is available, pin to one core (e.g. 0) for stability.

---

## CODE QUALITY (WITHIN PERF)

- Document invariants and register allocation at the top of each hot region.
- Keep macros minimal and transparent. No clever metaprogramming that obscures control flow.
- When you add an optimization, explain (briefly) why it should help and verify with make bench.
