#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES_FILE="$ROOT_DIR/tests/cases.txt"
BIN="$ROOT_DIR/lispasm"

if [[ ! -x "$BIN" ]]; then
  echo "binary not found: $BIN"
  exit 1
fi

pass_count=0
fail_count=0
line_no=0

while IFS= read -r line || [[ -n "$line" ]]; do
  line_no=$((line_no + 1))
  [[ -z "$line" || "$line" == \#* ]] && continue

  if [[ "$line" != *" => "* ]]; then
    echo "FAIL line $line_no: invalid case format"
    echo "  case: $line"
    fail_count=$((fail_count + 1))
    continue
  fi

  input="${line%% => *}"
  expected="${line#* => }"
  actual="$(printf '%s\n' "$input" | "$BIN")"

  if [[ "$actual" == "$expected" ]]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL line $line_no"
    echo "  input:    $input"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    fail_count=$((fail_count + 1))
  fi
done < "$CASES_FILE"

# Ensure REPL continues after an error line.
repl_input=$'(add 1 2)\n(div 4 0)\n(mul 3 3)\n'
repl_expected=$'3\nerror: division by zero\n9'
repl_actual="$(printf '%s' "$repl_input" | "$BIN")"
if [[ "$repl_actual" == "$repl_expected" ]]; then
  pass_count=$((pass_count + 1))
else
  echo "FAIL repl-continuation"
  echo "  expected:"
  printf '  %s\n' "$repl_expected"
  echo "  actual:"
  printf '  %s\n' "$repl_actual"
  fail_count=$((fail_count + 1))
fi

echo "Passed: $pass_count"
echo "Failed: $fail_count"

if [[ "$fail_count" -ne 0 ]]; then
  exit 1
fi
