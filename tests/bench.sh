#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-$ROOT_DIR/lispasm}"
SUITE_FILE="$ROOT_DIR/suite.txt"
WARMUP="${WARMUP:-3}"
RUNS="${RUNS:-11}"
CPU="${BENCH_CPU:-0}"

if [[ ! -x "$BIN" ]]; then
  echo "binary not found: $BIN" >&2
  exit 1
fi

if [[ ! -f "$SUITE_FILE" ]]; then
  echo "suite not found: $SUITE_FILE" >&2
  exit 1
fi

echo "validation: running exact-output suite stream check"
bash "$ROOT_DIR/tests/test.sh" suite-stream

python3 - "$BIN" "$SUITE_FILE" "$WARMUP" "$RUNS" "$CPU" <<'PY'
import shutil
import statistics
import subprocess
import sys
import time

bin_path = sys.argv[1]
suite_path = sys.argv[2]
warmup = int(sys.argv[3])
runs = int(sys.argv[4])
cpu = sys.argv[5]

if runs <= 0:
    raise SystemExit("RUNS must be > 0")
if warmup < 0:
    raise SystemExit("WARMUP must be >= 0")

base_cmd = [bin_path]
if cpu and shutil.which("taskset"):
    base_cmd = ["taskset", "-c", cpu] + base_cmd

def run_once() -> float:
    with open(suite_path, "rb") as fin, open("/dev/null", "wb") as devnull:
        t0 = time.perf_counter()
        proc = subprocess.run(
            base_cmd,
            stdin=fin,
            stdout=devnull,
            stderr=devnull,
            check=False,
        )
        dt = time.perf_counter() - t0
    if proc.returncode != 0:
        raise SystemExit(f"benchmark run failed with exit {proc.returncode}")
    return dt

for _ in range(warmup):
    run_once()

times = [run_once() for _ in range(runs)]

print(f"timed_runs={runs}")
print(f"warmup_runs={warmup}")
print(f"median={statistics.median(times):.6f}")
print(f"min={min(times):.6f}")
print(f"avg={statistics.mean(times):.6f}")
PY
