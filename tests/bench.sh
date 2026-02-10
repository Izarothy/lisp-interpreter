#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 <bin> [lines=400000] [expr='(add 1 2)']"
  exit 1
fi

BIN="$1"
LINES="${2:-400000}"
EXPR="${3:-"(add 1 2)"}"

if [[ ! -x "$BIN" ]]; then
  echo "binary not found: $BIN"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INPUT_FILE="$TMP_DIR/input.txt"
OUTPUT_FILE="$TMP_DIR/output.txt"

python3 - "$INPUT_FILE" "$LINES" "$EXPR" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = int(sys.argv[2])
expr = sys.argv[3]
path.write_text((expr + "\n") * lines)
PY

if command -v /usr/bin/time >/dev/null 2>&1; then
  /usr/bin/time -f "real=%e user=%U sys=%S" "$BIN" < "$INPUT_FILE" > "$OUTPUT_FILE"
else
  python3 - "$BIN" "$INPUT_FILE" "$OUTPUT_FILE" <<'PY'
import subprocess
import sys
import time

bin_path = sys.argv[1]
inp = open(sys.argv[2], "rb")
out = open(sys.argv[3], "wb")
t0 = time.perf_counter()
subprocess.run([bin_path], stdin=inp, stdout=out, check=True)
t1 = time.perf_counter()
print(f"real={t1-t0:.6f}")
PY
fi

echo "lines=$LINES"
wc -l "$OUTPUT_FILE" | awk '{print "output_lines="$1}'
