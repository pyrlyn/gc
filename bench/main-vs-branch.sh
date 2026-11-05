#!/bin/bash
# main vs branch for the epoch GC experiment (gc-improvement-experiment), one tree after the other:
#   bench/gc/main-vs-branch.sh <main-tree> <branch-tree> <out-dir>
# <main-tree> is a checkout of the baseline commit with bench/gc/pause-percentiles.patch applied (the
# instrumentation only: p50/p99 pauses). Per tree: compiler build, bench/gc/paced-run.sh (GC test suite,
# micro benchmarks: time, peak RSS, total/p50/p99/max pause, collections) and bench/gc/compare.sh epoch
# default (the full nkbench suite per GC). One file per benchmark in <out-dir>/<label>/.
set -u
here=$(cd "$(dirname "$0")" && pwd); out=$3; mkdir -p "$out"; out=$(cd "$out" && pwd)
for spec in "main:$1" "branch:$2"; do
  label=${spec%%:*}; tree=$(cd "${spec#*:}" && pwd); d=$out/$label; mkdir -p "$d"
  (cd "$tree/compiler" && ./build.sh > "$d/build.log" 2>&1) || { echo "build failed: $tree" >&2; exit 1; }
  "$here/paced-run.sh" "$tree" "$d"
  (cd "$tree" && ROUNDS=${ROUNDS:-3} bench/gc/compare.sh epoch perceus > /dev/null 2>&1)
  cp "$tree/bench/results/gc/nk-table.md" "$d/nk-table.md"
  for g in epoch perceus; do cp "$tree/bench/results/gc/nk-$g.txt" "$d/nk-$g.txt"; done
  echo "done $label $(git -C "$tree" rev-parse --short HEAD)"
done
