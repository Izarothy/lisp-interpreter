#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_A="${1:-${BIN_A:-}}"
BIN_B="${2:-${BIN_B:-$ROOT_DIR/lispasm}}"
SUITE_FILE="${SUITE_FILE:-$ROOT_DIR/suite.txt}"
WARMUP="${WARMUP:-3}"
RUNS="${RUNS:-21}"
CPU="${BENCH_CPU:-0}"
FORMAT="${BENCH_FORMAT:-text}"

case "$FORMAT" in
  text|json) ;;
  *)
    echo "invalid BENCH_FORMAT: $FORMAT (expected text|json)" >&2
    exit 1
    ;;
esac

if [[ -z "$BIN_A" ]]; then
  echo "usage: tests/bench_compare.sh <bin_a> [bin_b]" >&2
  echo "or set BIN_A=/path/to/baseline" >&2
  exit 1
fi

if [[ ! -x "$BIN_A" ]]; then
  echo "binary A not found or not executable: $BIN_A" >&2
  exit 1
fi

if [[ ! -x "$BIN_B" ]]; then
  echo "binary B not found or not executable: $BIN_B" >&2
  exit 1
fi

BIN_A="$(realpath "$BIN_A")"
BIN_B="$(realpath "$BIN_B")"

if [[ ! -f "$SUITE_FILE" ]]; then
  echo "suite not found: $SUITE_FILE" >&2
  exit 1
fi

if [[ "$FORMAT" == "json" ]]; then
  echo "validation: running exact-output suite stream check for A and B" >&2
  BIN="$BIN_A" bash "$ROOT_DIR/tests/test.sh" suite-stream >&2
  BIN="$BIN_B" bash "$ROOT_DIR/tests/test.sh" suite-stream >&2
else
  echo "validation: running exact-output suite stream check for A and B"
  BIN="$BIN_A" bash "$ROOT_DIR/tests/test.sh" suite-stream
  BIN="$BIN_B" bash "$ROOT_DIR/tests/test.sh" suite-stream
fi

python3 - "$BIN_A" "$BIN_B" "$SUITE_FILE" "$WARMUP" "$RUNS" "$CPU" "$FORMAT" <<'PY'
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone

bin_a = sys.argv[1]
bin_b = sys.argv[2]
suite_path = sys.argv[3]
warmup = int(sys.argv[4])
runs = int(sys.argv[5])
cpu = sys.argv[6]
output_format = sys.argv[7].strip().lower()

if runs <= 0:
    raise SystemExit("RUNS must be > 0")
if warmup < 0:
    raise SystemExit("WARMUP must be >= 0")

def cpu_fingerprint() -> str:
    parts = [platform.platform(), platform.processor(), platform.machine()]
    cpuinfo = "/proc/cpuinfo"
    if os.path.exists(cpuinfo):
        with open(cpuinfo, "rb") as f:
            parts.append(f.read().decode("utf-8", "replace"))
    payload = "\n".join(parts).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()

def base_cmd(path: str) -> list[str]:
    cmd = [path]
    if cpu and shutil.which("taskset"):
        cmd = ["taskset", "-c", cpu] + cmd
    return cmd

cmd_a = base_cmd(bin_a)
cmd_b = base_cmd(bin_b)
taskset_used = bool(cpu and shutil.which("taskset"))

def run_once(cmd: list[str]) -> float:
    with open(suite_path, "rb") as fin, open("/dev/null", "wb") as devnull:
        t0 = time.perf_counter()
        proc = subprocess.run(
            cmd,
            stdin=fin,
            stdout=devnull,
            stderr=devnull,
            check=False,
        )
        dt = time.perf_counter() - t0
    if proc.returncode != 0:
        raise SystemExit(f"benchmark run failed with exit {proc.returncode}: {' '.join(cmd)}")
    return dt

# Warm up both binaries with alternating order.
for i in range(warmup):
    if i % 2 == 0:
        run_once(cmd_a)
        run_once(cmd_b)
    else:
        run_once(cmd_b)
        run_once(cmd_a)

times_a: list[float] = []
times_b: list[float] = []

# Timed runs: interleave A/B to reduce drift and thermal bias.
for i in range(runs):
    if i % 2 == 0:
        times_a.append(run_once(cmd_a))
        times_b.append(run_once(cmd_b))
    else:
        times_b.append(run_once(cmd_b))
        times_a.append(run_once(cmd_a))

median_a = statistics.median(times_a)
median_b = statistics.median(times_b)
avg_a = statistics.mean(times_a)
avg_b = statistics.mean(times_b)
min_a = min(times_a)
min_b = min(times_b)

delta_vs_a = (median_b / median_a - 1.0) * 100.0

result = {
    "timed_runs_per_binary": runs,
    "warmup_runs_per_binary": warmup,
    "cpu_pin_requested": cpu,
    "taskset_used": taskset_used,
    "cpu_info_hash": cpu_fingerprint(),
    "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "a": {"path": bin_a, "median": median_a, "min": min_a, "avg": avg_a},
    "b": {"path": bin_b, "median": median_b, "min": min_b, "avg": avg_b},
    "delta_b_vs_a_pct": delta_vs_a,
}

if output_format == "json":
    print(json.dumps(result, sort_keys=True))
else:
    print(f"timed_runs_per_binary={runs}")
    print(f"warmup_runs_per_binary={warmup}")
    print(f"a_path={bin_a}")
    print(f"b_path={bin_b}")
    print(f"a_median={median_a:.6f}")
    print(f"b_median={median_b:.6f}")
    print(f"a_min={min_a:.6f}")
    print(f"b_min={min_b:.6f}")
    print(f"a_avg={avg_a:.6f}")
    print(f"b_avg={avg_b:.6f}")
    print(f"delta_b_vs_a_pct={delta_vs_a:+.2f}")
PY
