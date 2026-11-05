#!/bin/bash
# KotlinX benchmark suite (bench/nkbench.sh: warm-up + 5 runs, mean of the middle 3) per GC
# implementation, interleaved over ROUNDS rounds (median per case), then a table with the best value per row in bold.
#   bench/gc/compare.sh [gc ...]      (default: epoch boehm perceus)  -> bench/results/gc/nk-<gc>.txt, table on stdout,
#   and one file per benchmark: bench/results/gc-nk/<case>.json (one run per GC, see record.py)
set -eu
cd "$(dirname "$0")/.."
gcs=${*:-epoch boehm perceus}
# Boehm comes from bench/gc/third_party/boehm (benchmarks only): see gcdir.sh.
export NEWKOTLIN_GC_DIR="${NEWKOTLIN_GC_DIR:-$(sh gc/gcdir.sh)}"
rounds=${ROUNDS:-3}
mkdir -p results/gc; args=""
# Interleaved: ROUNDS rounds (default 3), each running every GC once, in rotated order, so drift in
# machine load affects all GCs alike; the table uses the per-case median over the rounds.
# Build every GC's binaries once, in parallel, before any timed run (cached by content in nkbuild.sh, so
# the rounds reuse them instead of recompiling 17 cases x GCs x ROUNDS times). No measurement overlaps a build.
for g in $gcs; do echo "$g"; done | xargs -P "${BUILD_JOBS:-4}" -I{} env NKBENCH_BUILD_ONLY=1 NKFLAGS="--gc={} ${NKFLAGS:-}" ./nkbench.sh "gc-build-{}"
set -- $gcs
for r in $(seq 1 "$rounds"); do
  for g in "$@"; do
    NKBENCH_SUITE=gc-nk NKFLAGS="--gc=$g ${NKFLAGS:-}" ./nkbench.sh "gc-$g-r$r" >/dev/null
    mv results/nk/gc-$g-r$r.txt results/gc/nk-$g-r$r.txt
  done
  g1=$1; shift; set -- "$@" "$g1"
done
for g in $gcs; do
  python3 - "$g" "$rounds" <<'PY'
import sys, statistics
g, n = sys.argv[1], int(sys.argv[2]); vals = {}; order = []
for r in range(1, n + 1):
    for line in open(f"results/gc/nk-{g}-r{r}.txt"):
        p = line.split()
        if len(p) == 2:
            if p[0] not in vals: vals[p[0]] = []; order.append(p[0])
            vals[p[0]].append(float(p[1]))
with open(f"results/gc/nk-{g}.txt", "w") as f:
    for c in order: f.write(f"{c} {round(statistics.median(vals[c]), 3)}\n")
PY
  rm -f results/gc/nk-$g-r*.txt
  args="$args $g=results/gc/nk-$g.txt"
done
python3 gc/table.py $args | tee results/gc/nk-table.md
