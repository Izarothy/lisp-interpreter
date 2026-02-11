#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE_FILE="$ROOT_DIR/suite.txt"
BIN="${BIN:-$ROOT_DIR/lispasm}"
MODE="${1:-cases}"

if [[ ! -x "$BIN" ]]; then
  echo "binary not found: $BIN" >&2
  exit 1
fi

if [[ ! -f "$SUITE_FILE" ]]; then
  echo "suite not found: $SUITE_FILE" >&2
  exit 1
fi

python3 - "$MODE" "$BIN" "$SUITE_FILE" <<'PY'
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

I64_MIN = -(1 << 63)
I64_MAX = (1 << 63) - 1
LINE_LIMIT = 65535

ERR_UNEXPECTED = "error: unexpected token"
ERR_UNMATCHED = "error: unmatched parenthesis"
ERR_MISSING = "error: missing arguments"
ERR_UNKNOWN = "error: unknown symbol"
ERR_DIV_ZERO = "error: division by zero"
ERR_OVERFLOW = "error: integer overflow"
ERR_LINE_TOO_LONG = "error: line too long"


class EvalError(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def is_ws(ch: str) -> bool:
    return ch in (" ", "\t", "\r")


def is_delim(ch: str | None) -> bool:
    return ch is None or ch in (" ", "\t", "\r", "(", ")")


def checked_add(a: int, b: int) -> int:
    v = a + b
    if v < I64_MIN or v > I64_MAX:
        raise EvalError(ERR_OVERFLOW)
    return v


def checked_sub(a: int, b: int) -> int:
    v = a - b
    if v < I64_MIN or v > I64_MAX:
        raise EvalError(ERR_OVERFLOW)
    return v


def checked_mul(a: int, b: int) -> int:
    v = a * b
    if v < I64_MIN or v > I64_MAX:
        raise EvalError(ERR_OVERFLOW)
    return v


def trunc_div(a: int, b: int) -> int:
    q = abs(a) // abs(b)
    return -q if (a < 0) ^ (b < 0) else q


@dataclass
class Parser:
    s: str
    i: int = 0

    def peek(self) -> str | None:
        if self.i >= len(self.s):
            return None
        return self.s[self.i]

    def skip_ws(self) -> None:
        n = len(self.s)
        i = self.i
        while i < n and is_ws(self.s[i]):
            i += 1
        self.i = i

    def parse_number(self) -> int:
        n = len(self.s)
        i = self.i
        neg = False
        if i < n and self.s[i] == "-":
            neg = True
            i += 1
        if i >= n or not self.s[i].isdigit():
            raise EvalError(ERR_UNEXPECTED)

        limit_last = 8 if neg else 7
        acc = 0
        while i < n and self.s[i].isdigit():
            d = ord(self.s[i]) - 48
            if acc > 922337203685477580 or (acc == 922337203685477580 and d > limit_last):
                raise EvalError(ERR_OVERFLOW)
            acc = acc * 10 + d
            i += 1

        if i < n and not is_delim(self.s[i]):
            raise EvalError(ERR_UNEXPECTED)

        self.i = i
        return -acc if neg else acc

    def parse_symbol(self) -> str:
        n = len(self.s)
        i = self.i
        start = i
        while i < n and not is_delim(self.s[i]):
            i += 1
        tok = self.s[start:i]
        self.i = i
        if tok not in ("add", "sub", "mul", "div"):
            raise EvalError(ERR_UNKNOWN)
        return tok

    def parse_expr(self) -> int:
        self.skip_ws()
        ch = self.peek()
        if ch is None:
            raise EvalError(ERR_UNEXPECTED)
        if ch == "(":
            self.i += 1
            self.skip_ws()
            ch = self.peek()
            if ch is None:
                raise EvalError(ERR_UNMATCHED)
            if ch == ")":
                raise EvalError(ERR_UNEXPECTED)

            if ch == "-" or ch.isdigit():
                val = self.parse_number()
                self.skip_ws()
                ch = self.peek()
                if ch is None:
                    raise EvalError(ERR_UNMATCHED)
                if ch != ")":
                    raise EvalError(ERR_UNEXPECTED)
                self.i += 1
                return val

            if not ch.isalpha():
                raise EvalError(ERR_UNEXPECTED)

            op = self.parse_symbol()
            args: list[int] = []
            while True:
                self.skip_ws()
                ch = self.peek()
                if ch is None:
                    raise EvalError(ERR_UNMATCHED)
                if ch == ")":
                    self.i += 1
                    break
                args.append(self.parse_expr())

            if op == "add":
                if not args:
                    raise EvalError(ERR_MISSING)
                acc = args[0]
                for v in args[1:]:
                    acc = checked_add(acc, v)
                return acc
            if op == "mul":
                if not args:
                    raise EvalError(ERR_MISSING)
                acc = args[0]
                for v in args[1:]:
                    acc = checked_mul(acc, v)
                return acc
            if op == "sub":
                if not args:
                    raise EvalError(ERR_MISSING)
                if len(args) == 1:
                    if args[0] == I64_MIN:
                        raise EvalError(ERR_OVERFLOW)
                    return -args[0]
                acc = args[0]
                for v in args[1:]:
                    acc = checked_sub(acc, v)
                return acc
            if op == "div":
                if len(args) < 2:
                    raise EvalError(ERR_MISSING)
                acc = args[0]
                for v in args[1:]:
                    if v == 0:
                        raise EvalError(ERR_DIV_ZERO)
                    if acc == I64_MIN and v == -1:
                        raise EvalError(ERR_OVERFLOW)
                    acc = trunc_div(acc, v)
                return acc
            raise EvalError(ERR_UNKNOWN)

        if ch == "-" or ch.isdigit():
            return self.parse_number()
        raise EvalError(ERR_UNEXPECTED)


def evaluate_line(line: str) -> tuple[str, bool]:
    if len(line) > LINE_LIMIT:
        return ERR_LINE_TOO_LONG, True
    if line.strip(" \t\r") == "":
        return "", False
    parser = Parser(line)
    try:
        value = parser.parse_expr()
        parser.skip_ws()
        if parser.peek() is not None:
            raise EvalError(ERR_UNEXPECTED)
        return str(value), False
    except EvalError as e:
        return e.reason, True


def parse_suite(path: Path) -> list[tuple[str, str, bool]]:
    cases: list[tuple[str, str, bool]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw.strip() == "":
            continue
        if "=>" in raw:
            left, right = raw.split("=>", 1)
            inp = left.rstrip(" \t")
            exp = right.lstrip(" \t")
            is_err = exp.startswith("error: ")
            cases.append((inp, exp, is_err))
            continue
        exp, is_err = evaluate_line(raw)
        cases.append((raw, exp, is_err))
    return cases


def expected_streams(cases: list[tuple[str, str, bool]]) -> tuple[bytes, bytes]:
    out = bytearray()
    err = bytearray()
    for _, exp, is_err in cases:
        if exp == "":
            continue
        if is_err:
            err.extend(exp.encode("utf-8"))
            err.append(0x0A)
        else:
            out.extend(exp.encode("utf-8"))
            out.append(0x0A)
    return bytes(out), bytes(err)


def first_diff(a: bytes, b: bytes) -> str:
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return f"offset={i} expected=0x{a[i]:02x} actual=0x{b[i]:02x}"
    if len(a) != len(b):
        return f"length expected={len(a)} actual={len(b)}"
    return "no diff"


def run_cases(bin_path: Path, cases: list[tuple[str, str, bool]]) -> int:
    passes = 0
    fails = 0
    for idx, (inp, exp, is_err) in enumerate(cases, 1):
        proc = subprocess.run(
            [str(bin_path)],
            input=(inp + "\n").encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        expected_stdout = b""
        expected_stderr = b""
        if exp != "":
            if is_err:
                expected_stderr = (exp + "\n").encode("utf-8")
            else:
                expected_stdout = (exp + "\n").encode("utf-8")
        ok = (
            proc.returncode == 0
            and proc.stdout == expected_stdout
            and proc.stderr == expected_stderr
        )
        if ok:
            passes += 1
            continue
        fails += 1
        print(f"FAIL case={idx}")
        print(f"  input: {inp!r}")
        print(f"  returncode expected=0 actual={proc.returncode}")
        print(f"  stdout {first_diff(expected_stdout, proc.stdout)}")
        print(f"  stderr {first_diff(expected_stderr, proc.stderr)}")

    print(f"Passed: {passes}")
    print(f"Failed: {fails}")
    return 0 if fails == 0 else 1


def run_suite_stream(bin_path: Path, suite_path: Path, cases: list[tuple[str, str, bool]]) -> int:
    expected_stdout, expected_stderr = expected_streams(cases)
    with suite_path.open("rb") as f:
        proc = subprocess.run(
            [str(bin_path)],
            stdin=f,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    if proc.returncode != 0:
        print(f"FAIL stream returncode expected=0 actual={proc.returncode}")
        return 1
    if proc.stdout != expected_stdout:
        print("FAIL stream stdout mismatch")
        print("  " + first_diff(expected_stdout, proc.stdout))
        return 1
    if proc.stderr != expected_stderr:
        print("FAIL stream stderr mismatch")
        print("  " + first_diff(expected_stderr, proc.stderr))
        return 1
    print("Suite stream validation: PASS")
    return 0


def main() -> int:
    mode = sys.argv[1]
    bin_path = Path(sys.argv[2])
    suite_path = Path(sys.argv[3])
    cases = parse_suite(suite_path)
    if mode == "cases":
        return run_cases(bin_path, cases)
    if mode == "suite-stream":
        return run_suite_stream(bin_path, suite_path, cases)
    print(f"unknown mode: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
PY
