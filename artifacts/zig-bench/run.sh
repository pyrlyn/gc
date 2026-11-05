#!/bin/bash
# Native Zig ops benches, same method as the frozen C baseline:
# N=4000000, 5 interleaved rounds, median; then size sweep; then RSS via wait4.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${ZIG_BIN:-$HOME/.local/bin}:$PATH"
OUT="$ROOT/zig-out/bin"
LOG="$(cd "$(dirname "$0")" && pwd)/logs"
mkdir -p "$LOG"
cd "$ROOT"
zig version | tee "$LOG/zig-version.txt"
echo "optimize=--release=fast lto=true" | tee -a "$LOG/zig-version.txt"
echo "load=$(cat /proc/loadavg) date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee "$LOG/environment.txt"
# Install optimized binaries; run them interleaved below (do not use `zig build bench`,
# which would time a single non-interleaved pass).
zig build --release=fast
GCS="perceus incremental epoch rc"
N=4000000
{
  echo "# start $(date -u +%Y-%m-%dT%H:%M:%SZ) load=$(cat /proc/loadavg)"
  for r in 1 2 3 4 5; do
    echo "# round $r"
    for g in $GCS; do
      "$OUT/gc-ops-$g" "$N" | sed "s/^[^ ]*/$g/"
    done
  done
  echo "# end $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$LOG/ops-raw.txt"

python3 - <<'PY' | tee "$LOG/ops-table.md"
import collections, statistics, pathlib
d = collections.defaultdict(list)
for l in pathlib.Path("/workspace/artifacts/zig-bench/logs/ops-raw.txt").read_text().splitlines():
    if l.startswith("#") or not l.strip(): continue
    g, op, v = l.split()
    d[(op,g)].append(float(v))
gcs=["perceus","incremental","epoch","rc"]
ops=["rc_pair","field_store","alloc_drop","lru_move","pause_ms"]
print("| op (ns/op) | " + " | ".join(gcs) + " |")
print("|---|" + "---:|"*len(gcs))
for o in ops:
    print("| "+o+" | "+" | ".join("%.2f"%statistics.median(d[(o,g)]) for g in gcs)+" |")
print("\nraw:")
for k,xs in d.items():
    print(f"  {k[1]} {k[0]}: {xs} med={statistics.median(xs):.2f}")
PY

{
  echo "# size sweep"
  for n in 100000 1000000 4000000; do
    echo "## N=$n"
    for r in 1 2 3; do
      for g in $GCS; do
        echo -n "N=$n round=$r "
        "$OUT/gc-ops-$g" "$n"
      done
    done
  done
} | tee "$LOG/ops-size-sweep.txt"

{
  echo "# rss"
  for g in $GCS; do
    echo "## $g"
    python3 "$ROOT/artifacts/c-baseline/run_with_rusage.py" "$OUT/gc-ops-$g" 4000000 2>&1
  done
} | tee "$LOG/ops-rss.txt"
echo DONE
