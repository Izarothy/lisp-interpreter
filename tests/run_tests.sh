#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES_FILE="$ROOT_DIR/tests/cases.txt"
BIN="${BIN:-$ROOT_DIR/lispasm}"

if [[ ! -x "$BIN" ]]; then
  echo "binary not found: $BIN"
  exit 1
fi

pass_count=0
fail_count=0
line_no=0

write_expected_stream() {
  local path="$1"
  local payload="$2"
  if [[ -z "$payload" ]]; then
    : > "$path"
  else
    printf '%s\n' "$payload" > "$path"
  fi
}

show_hex() {
  local path="$1"
  od -An -tx1 -v "$path" | sed 's/^/    /'
}

run_stream_case() {
  local label="$1"
  local input_payload="$2"
  local expected_stdout="$3"
  local expected_stderr="$4"
  local expected_exit="${5:-0}"

  local in_file out_file err_file exp_out_file exp_err_file status
  in_file="$(mktemp)"
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  exp_out_file="$(mktemp)"
  exp_err_file="$(mktemp)"

  printf '%s' "$input_payload" > "$in_file"
  write_expected_stream "$exp_out_file" "$expected_stdout"
  write_expected_stream "$exp_err_file" "$expected_stderr"

  if "$BIN" <"$in_file" >"$out_file" 2>"$err_file"; then
    status=0
  else
    status=$?
  fi

  if [[ "$status" -ne "$expected_exit" ]]; then
    echo "FAIL $label"
    echo "  expected exit: $expected_exit"
    echo "  actual exit:   $status"
    fail_count=$((fail_count + 1))
    rm -f "$in_file" "$out_file" "$err_file" "$exp_out_file" "$exp_err_file"
    return
  fi

  if ! cmp -s "$out_file" "$exp_out_file"; then
    echo "FAIL $label"
    echo "  stdout mismatch (byte-exact)"
    echo "  expected stdout hex:"
    show_hex "$exp_out_file"
    echo "  actual stdout hex:"
    show_hex "$out_file"
    fail_count=$((fail_count + 1))
    rm -f "$in_file" "$out_file" "$err_file" "$exp_out_file" "$exp_err_file"
    return
  fi

  if ! cmp -s "$err_file" "$exp_err_file"; then
    echo "FAIL $label"
    echo "  stderr mismatch (byte-exact)"
    echo "  expected stderr hex:"
    show_hex "$exp_err_file"
    echo "  actual stderr hex:"
    show_hex "$err_file"
    fail_count=$((fail_count + 1))
    rm -f "$in_file" "$out_file" "$err_file" "$exp_out_file" "$exp_err_file"
    return
  fi

  rm -f "$in_file" "$out_file" "$err_file" "$exp_out_file" "$exp_err_file"
  pass_count=$((pass_count + 1))
}

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

  if [[ "$expected" == error:* ]]; then
    run_stream_case "line-$line_no" "$input"$'\n' "" "$expected"
  else
    run_stream_case "line-$line_no" "$input"$'\n' "$expected" ""
  fi

done < "$CASES_FILE"

# REPL stream separation and continuation after an error line.
run_stream_case \
  "repl-continuation" \
  $'(add 1 2)\n(div 4 0)\n(mul 3 3)\n' \
  $'3\n9' \
  $'error: division by zero'

# Blank-line behavior: blank lines are ignored and REPL continues.
run_stream_case \
  "blank-line-behavior" \
  $'\n(add 1 2)\n' \
  $'3' \
  ''

# Overlong line should emit one error and continue at next line.
long_line="$(printf '%5000s' '' | tr ' ' '1')"
run_stream_case \
  "long-line-recovery" \
  "${long_line}"$'\n(add 1 2)\n' \
  $'3' \
  $'error: line too long'

# Fatal read failure path: closed stdin must exit with code 1.
fatal_err_file="$(mktemp)"
fatal_expected_file="$(mktemp)"
printf '%s\n' 'fatal: stdin read failure' > "$fatal_expected_file"
if "$BIN" <&- > /dev/null 2>"$fatal_err_file"; then
  fatal_status=0
else
  fatal_status=$?
fi
if cmp -s "$fatal_err_file" "$fatal_expected_file"; then
  fatal_match=1
else
  fatal_match=0
fi
if [[ "$fatal_status" -ne 1 || "$fatal_match" -ne 1 ]]; then
  echo "FAIL fatal-read"
  echo "  expected exit: 1"
  echo "  actual exit:   $fatal_status"
  echo "  expected stderr hex:"
  show_hex "$fatal_expected_file"
  echo "  actual stderr hex:"
  show_hex "$fatal_err_file"
  fail_count=$((fail_count + 1))
else
  pass_count=$((pass_count + 1))
fi
rm -f "$fatal_err_file" "$fatal_expected_file"

# Fatal write failure path: closed stdout must exit with code 2.
fatal_in_file="$(mktemp)"
printf '(add 1 2)\n' > "$fatal_in_file"
fatal_err_file="$(mktemp)"
fatal_expected_file="$(mktemp)"
printf '%s\n' 'fatal: stdout write failure' > "$fatal_expected_file"
if "$BIN" < "$fatal_in_file" 1>&- 2>"$fatal_err_file"; then
  fatal_status=0
else
  fatal_status=$?
fi
if cmp -s "$fatal_err_file" "$fatal_expected_file"; then
  fatal_match=1
else
  fatal_match=0
fi
if [[ "$fatal_status" -ne 2 || "$fatal_match" -ne 1 ]]; then
  echo "FAIL fatal-stdout"
  echo "  expected exit: 2"
  echo "  actual exit:   $fatal_status"
  echo "  expected stderr hex:"
  show_hex "$fatal_expected_file"
  echo "  actual stderr hex:"
  show_hex "$fatal_err_file"
  fail_count=$((fail_count + 1))
else
  pass_count=$((pass_count + 1))
fi
rm -f "$fatal_in_file" "$fatal_err_file" "$fatal_expected_file"

echo "Passed: $pass_count"
echo "Failed: $fail_count"

if [[ "$fail_count" -ne 0 ]]; then
  exit 1
fi
