#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-$ROOT_DIR/lispasm}"
SUITE_FILE="$ROOT_DIR/suite.txt"
WARMUP="${WARMUP:-3}"
RUNS="${RUNS:-11}"
CPU="${BENCH_CPU:-0}"
FORMAT="${BENCH_FORMAT:-text}"

case "$FORMAT" in
  text|json) ;;
  *)
    echo "invalid BENCH_FORMAT: $FORMAT (expected text|json)" >&2
    exit 1
    ;;
esac

if [[ ! -x "$BIN" ]]; then
  echo "binary not found: $BIN" >&2
  exit 1
fi

if [[ ! -f "$SUITE_FILE" ]]; then
  echo "suite not found: $SUITE_FILE" >&2
  exit 1
fi

if [[ "$FORMAT" == "json" ]]; then
  echo "validation: running exact-output suite stream check" >&2
  bash "$ROOT_DIR/tests/test.sh" suite-stream >&2
else
  echo "validation: running exact-output suite stream check"
  bash "$ROOT_DIR/tests/test.sh" suite-stream
fi

python3 - "$BIN" "$SUITE_FILE" "$WARMUP" "$RUNS" "$CPU" "$FORMAT" <<'PY'
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

bin_path = sys.argv[1]
suite_path = sys.argv[2]
warmup = int(sys.argv[3])
runs = int(sys.argv[4])
cpu = sys.argv[5]
output_format = sys.argv[6].strip().lower()

if runs <= 0:
    raise SystemExit("RUNS must be > 0")
if warmup < 0:
    raise SystemExit("WARMUP must be >= 0")
if output_format not in ("text", "json"):
    raise SystemExit("BENCH_FORMAT must be text or json")

base_cmd = [bin_path]
taskset_used = False
if cpu and shutil.which("taskset"):
    base_cmd = ["taskset", "-c", cpu] + base_cmd
    taskset_used = True

def cpu_fingerprint() -> str:
    parts = [platform.platform(), platform.processor(), platform.machine()]
    cpuinfo = "/proc/cpuinfo"
    if os.path.exists(cpuinfo):
        with open(cpuinfo, "rb") as f:
            parts.append(f.read().decode("utf-8", "replace"))
    payload = "\n".join(parts).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()

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

result = {
    "timed_runs": runs,
    "warmup_runs": warmup,
    "median": statistics.median(times),
    "min": min(times),
    "avg": statistics.mean(times),
    "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "taskset_used": taskset_used,
    "cpu_pin_requested": cpu,
    "cpu_info_hash": cpu_fingerprint(),
}

if output_format == "json":
    print(json.dumps(result, sort_keys=True))
else:
    print(f"timed_runs={result['timed_runs']}")
    print(f"warmup_runs={result['warmup_runs']}")
    print(f"median={result['median']:.6f}")
    print(f"min={result['min']:.6f}")
    print(f"avg={result['avg']:.6f}")
PY
