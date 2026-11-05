#!/bin/bash
# HISTORICAL: the KX_GC_PAR_MIN_* thresholds were removed (cost model, see par-auto.sh); kept for d2-threshold*.
# Parallel-detection threshold sweep (epoch): for each benchmark, threshold mode (live objects:
# KX_GC_PAR_MIN_OBJECTS, traced heap bytes: KX_GC_PAR_MIN_HEAP_BYTES) and value, run KX_GC_THREADS=1/2/4
# (median of RUNS, default 3) and record max GC pause and run time (the benchmark's own nanos).
# Writes bench/results/gc/exp/d2-threshold/<case>.md: rows = threshold, columns = threads, best in bold.
set -eu
cd "$(dirname "$0")/.."
NKC=${NKC:-../bin/newkotlinc}
runs=${RUNS:-3}
out=${OUT:-results/gc/exp/d2-threshold}; tmp=../compiler/build/gcpar; mkdir -p "$out" "$tmp"
cases="${CASES:-cyclic_garbage live_heap_churn big_live_churn bigheap}"
OBJ="${OBJ:-0 10000 100000 1000000 10000000}"
HEAP="${HEAP:-0 4194304 16777216 67108864 268435456}"
src() { if [ -f "gc/micro/$1.kt" ]; then echo "gc/micro/$1.kt"; else echo "cases/$1/kotlin/Main.kt"; fi; }
med() { python3 -c "import statistics,sys; v=[float(x) for x in sys.argv[1:]]; print(round(statistics.median(v),3) if v else 0)" "$@"; }
for c in $cases; do
  b="$tmp/$c"; "$NKC" --gc=epoch "$(src $c)" -o "$b"
  for t in 1 2 4; do : > "$tmp/$c.pause.$t"; : > "$tmp/$c.time.$t"; done
  for mode in objects heap; do
    if [ $mode = objects ]; then vals=$OBJ; var=KX_GC_PAR_MIN_OBJECTS; else vals=$HEAP; var=KX_GC_PAR_MIN_HEAP_BYTES; fi
    for v in $vals; do
      for t in 1 2 4; do
        ps=""; ts=""
        for r in $(seq "$runs"); do
          o=$(env $var=$v KX_GC_THREADS=$t KX_GC_STATS=1 BENCH_DATA=data/words.txt "$b" 2>&1)
          ps="$ps $(echo "$o" | grep -oE 'pause_max=[0-9.]+' | cut -d= -f2)"
          ts="$ts $(echo "$o" | grep -oE 'nanos=[0-9]+' | cut -d= -f2 | awk '{print $1/1e6}')"
        done
        echo "$mode=$v $(med $ps)" >> "$tmp/$c.pause.$t"
        echo "$mode=$v $(med $ts)" >> "$tmp/$c.time.$t"
      done
    done
  done
  { echo "# $c: parallel detection threshold sweep (median of $runs; $(date '+%Y-%m-%d %H:%M %Z'); load $(sysctl -n vm.loadavg); commit $(git rev-parse --short HEAD))"; echo
    python3 gc/table.py --metric "threshold, max GC pause ms" T1=$tmp/$c.pause.1 T2=$tmp/$c.pause.2 T4=$tmp/$c.pause.4; echo
    python3 gc/table.py --metric "threshold, run time ms" T1=$tmp/$c.time.1 T2=$tmp/$c.time.2 T4=$tmp/$c.time.4; } > "$out/$c.md"
  cat "$out/$c.md"
done
