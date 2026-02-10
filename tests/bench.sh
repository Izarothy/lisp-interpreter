#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 5 ]]; then
  echo "usage: $0 <bin> [lines=400000] [expr='(add 1 2)'] [runs=7] [warmup=1]"
  echo "env:"
  echo "  BENCH_CPU=<cpu_id_or_list>  Optional CPU affinity (uses taskset if available)"
  exit 1
fi

BIN="$1"
LINES="${2:-400000}"
EXPR="${3:-"(add 1 2)"}"
RUNS="${4:-7}"
WARMUP="${5:-1}"

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

line = (expr + "\n").encode()
if lines < 0:
    raise SystemExit("lines must be >= 0")

# Stream to disk in fixed-size chunks to avoid a giant intermediate string.
target_chunk_bytes = 1 << 20
repeat = max(1, target_chunk_bytes // max(1, len(line)))
chunk = line * repeat

with path.open("wb", buffering=1 << 20) as f:
    full_chunks, rem = divmod(lines, repeat)
    for _ in range(full_chunks):
        f.write(chunk)
    if rem:
        f.write(line * rem)
PY

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || ! [[ "$WARMUP" =~ ^[0-9]+$ ]]; then
  echo "runs and warmup must be non-negative integers"
  exit 1
fi

python3 - "$BIN" "$INPUT_FILE" "$RUNS" "$WARMUP" "${BENCH_CPU:-}" <<'PY'
import subprocess
import sys
import time
import statistics
import shutil

bin_path = sys.argv[1]
input_path = sys.argv[2]
runs = int(sys.argv[3])
warmup = int(sys.argv[4])
cpu = sys.argv[5]

cmd = [bin_path]
if cpu and shutil.which("taskset"):
    cmd = ["taskset", "-c", cpu] + cmd

def run_once():
    with open(input_path, "rb") as fin, open("/dev/null", "wb") as fout:
        t0 = time.perf_counter()
        subprocess.run(cmd, stdin=fin, stdout=fout, stderr=subprocess.DEVNULL, check=True)
        return time.perf_counter() - t0

for _ in range(warmup):
    run_once()

times = [run_once() for _ in range(runs)]
if not times:
    print("timed_runs=0")
    print("real_median=0.000000")
    print("real_min=0.000000")
    print("real_avg=0.000000")
else:
    print(f"timed_runs={runs}")
    print(f"real_median={statistics.median(times):.6f}")
    print(f"real_min={min(times):.6f}")
    print(f"real_avg={statistics.mean(times):.6f}")
PY

# Separate correctness run: write real output once and validate line count.
"$BIN" < "$INPUT_FILE" > "$OUTPUT_FILE"
output_lines="$(wc -l < "$OUTPUT_FILE" | tr -d '[:space:]')"
if [[ "$output_lines" != "$LINES" ]]; then
  echo "line_count_mismatch expected=$LINES actual=$output_lines"
  exit 1
fi

echo "lines=$LINES"
echo "output_lines=$output_lines"
