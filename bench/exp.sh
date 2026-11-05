#!/bin/bash
# GC experiment benchmarks: max GC pause (KX_GC_STATS=1) and peak RSS (/usr/bin/time -l), median of RUNS
# (default 3) interleaved runs per variant, for the GC micros and the cycles / lru cases.
#   bench/gc/exp.sh [label ...]     (default: default epoch-base epoch)
# Labels: default | epoch (this tree's compiler/gc) | epoch-base (EPOCH_BASE_GC_DIR, default
# ../kotlinx-gc/compiler/gc: the gc/epoch baseline worktree). Extra env per run: EXP_ENV="K=V ...".
# Writes one file per benchmark: bench/results/gc/exp/$STEP/<case>.md (best value per row in bold).
set -eu
cd "$(dirname "$0")/.."
NKC=${NKC:-../bin/newkotlinc}
labels=${*:-default epoch-base epoch}
runs=${RUNS:-3}
base=${EPOCH_BASE_GC_DIR:-$(cd ../.. && pwd)/kotlinx-gc/compiler/gc}
out=results/gc/exp/${STEP:-current}; tmp=../compiler/build/gcexp; mkdir -p "$out" "$tmp"
cases="${CASES:-alloc_throughput cyclic_garbage live_heap_churn bigheap cycles lru}"
src() { if [ -f "gc/micro/$1.kt" ]; then echo "gc/micro/$1.kt"; else echo "cases/$1/kotlin/Main.kt"; fi; }
for c in $cases; do
  for l in $labels; do
    case $l in
      default) "$NKC" --gc=perceus "$(src $c)" -o "$tmp/$l.$c" ;;
      epoch) "$NKC" --gc=epoch "$(src $c)" -o "$tmp/$l.$c" ;;
      epoch-base) NEWKOTLIN_GC_DIR="$base" "$NKC" --gc=epoch "$(src $c)" -o "$tmp/$l.$c" ;;
    esac
    : > "$tmp/$l.$c.pause"; : > "$tmp/$l.$c.rss"
  done
  for r in $(seq "$runs"); do
    for l in $labels; do
      b="$tmp/$l.$c"
      o=$( { env BENCH_DATA=data/words.txt KX_GC_STATS=1 ${EXP_ENV:-} /usr/bin/time -l "$b" >/dev/null; } 2>&1 )
      echo "$o" | grep -oE 'pause_max=[0-9.]+' | cut -d= -f2 >> "$tmp/$l.$c.pause"
      echo "$o" | awk '/maximum resident set size/ {printf "%.1f\n", $1/1048576}' >> "$tmp/$l.$c.rss"
    done
  done
  { echo "# $c (median of $runs runs; $(date '+%Y-%m-%d %H:%M %Z'); commit $(git rev-parse --short HEAD))"; echo
    for m in pause:"max GC pause ms" rss:"peak RSS MiB"; do
      k=${m%%:*}; args=""
      for l in $labels; do
        python3 -c "import statistics,sys; v=[float(x) for x in open('$tmp/$l.$c.$k') if x.strip()]; print('$c', round(statistics.median(v),3) if v else 0)" > "$tmp/$l.$c.$k.med"
        args="$args $l=$tmp/$l.$c.$k.med"
      done
      python3 gc/table.py --metric "${m#*:}" $args; echo
    done; } > "$out/$c.md"
  cat "$out/$c.md"
done
