#!/bin/bash
# Automatic parallel detection (cost model, no thresholds) vs default GC: for each benchmark, run
# default, epoch KX_GC_THREADS=1 and epoch KX_GC_THREADS=4 (median of RUNS, default 3, interleaved) and
# record max GC pause, run time (the benchmark's own nanos) and peak RSS.
# Writes one file per benchmark: bench/results/gc/exp/${STEP:-d2-auto}/<case>.md (best value per row in bold).
set -eu
cd "$(dirname "$0")/.."
NKC=${NKC:-../bin/newkotlinc}
runs=${RUNS:-3}
out=results/gc/exp/${STEP:-d2-auto}; tmp=../compiler/build/gcauto; mkdir -p "$out" "$tmp"
cases="${CASES:-alloc_throughput cyclic_garbage live_heap_churn bigheap huge_live_churn wide_graph_churn cycles lru}"
labels="default epoch-T1 epoch-T4"
src() { if [ -f "gc/micro/$1.kt" ]; then echo "gc/micro/$1.kt"; else echo "cases/$1/kotlin/Main.kt"; fi; }
for c in $cases; do
  "$NKC" --gc=perceus "$(src $c)" -o "$tmp/default.$c"; "$NKC" --gc=epoch "$(src $c)" -o "$tmp/epoch.$c"
  for l in $labels; do for m in pause time rss; do : > "$tmp/$l.$c.$m"; done; done
  for r in $(seq "$runs"); do
    for l in $labels; do
      case $l in default) b=$tmp/default.$c; t=1 ;; epoch-T1) b=$tmp/epoch.$c; t=1 ;; epoch-T4) b=$tmp/epoch.$c; t=4 ;; esac
      o=$( { env KX_GC_THREADS=$t KX_GC_STATS=1 BENCH_DATA=data/words.txt /usr/bin/time -l "$b"; } 2>&1 )
      echo "$o" | grep -oE 'pause_max=[0-9.]+' | cut -d= -f2 >> "$tmp/$l.$c.pause"
      echo "$o" | grep -oE 'nanos=[0-9]+' | cut -d= -f2 | awk '{print $1/1e6}' >> "$tmp/$l.$c.time"
      echo "$o" | awk '/maximum resident set size/ {printf "%.1f\n", $1/1048576}' >> "$tmp/$l.$c.rss"
    done
  done
  { echo "# $c (median of $runs runs; $(date '+%Y-%m-%d %H:%M %Z'); load $(sysctl -n vm.loadavg); commit $(git rev-parse --short HEAD))"; echo
    for m in pause:"max GC pause ms" time:"run time ms" rss:"peak RSS MiB"; do
      k=${m%%:*}; args=""
      for l in $labels; do
        python3 -c "import statistics; v=[float(x) for x in open('$tmp/$l.$c.$k') if x.strip()]; print('$c', round(statistics.median(v),3) if v else 0)" > "$tmp/$l.$c.$k.med"
        args="$args $l=$tmp/$l.$c.$k.med"
      done
      python3 gc/table.py --metric "${m#*:}" $args; echo
    done; } > "$out/$c.md"
  cat "$out/$c.md"
done
