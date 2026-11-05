#!/bin/bash
# GC-only microbenchmarks (bench/gc/micro/*.kt) per GC implementation: time (warm-up + 5 runs, mean of the
# middle 3), peak RSS (/usr/bin/time -l), and the collector's own statistics (KX_GC_STATS=1: collections,
# total, p50, p99 and max pause). Writes bench/results/gc/micro-<gc>-<metric>.txt and prints one table per metric
# (best value per row in bold).   bench/gc/micro.sh [gc ...]   (default: epoch boehm perceus)
# One file per benchmark: bench/results/gc-micro/<bench>.json (one run per GC with all metrics, see record.py).
set -eu
cd "$(dirname "$0")/.."
NKC=${NKC:-../bin/newkotlinc}
gcs=${*:-epoch boehm perceus}
# Boehm comes from bench/gc/third_party/boehm (benchmarks only): see gcdir.sh.
export NEWKOTLIN_GC_DIR="${NEWKOTLIN_GC_DIR:-$(sh gc/gcdir.sh)}"
mkdir -p results/gc ../compiler/build/gcmicro
for g in $gcs; do for m in time rss pause_total pause_max pause_p50 pause_p99 collections; do : > results/gc/micro-$g-$m.txt; done; done
# Opt-in, off by default (the default run measures everything):
#   MICRO_SKIP="gc:case ..."  skip these pairs entirely (e.g. "default:wide_graph_churn incremental:wide_graph_churn");
#   MICRO_MAX_S=N             skip a pair whose warm-up run takes longer than N seconds (its rows show "—").
# Skipped pairs get no row and no record.py entry, so they never mix with full measurements.
skip=" ${MICRO_SKIP:-} "
# Build every (case, GC) binary up front, in parallel (BUILD_JOBS, default 4), through the nkbuild.sh
# content cache; no timed run overlaps a build.
for src in gc/micro/*.kt; do for g in $gcs; do echo "$g $src"; done; done |
  xargs -P "${BUILD_JOBS:-4}" -L1 sh -c './nkbuild.sh "../compiler/build/gcmicro/$0.$(basename "$1" .kt)" "'"$NKC"'" "$1" --gc="$0"'
# Interleaved: every timed run goes through all GCs before the next one, so load drift hits all alike.
for src in gc/micro/*.kt; do
  c=$(basename "$src" .kt); run=""
  for g in $gcs; do
    b=../compiler/build/gcmicro/$g.$c; eval "ts_$g=''"
    case $skip in *" $g:$c "*) echo "micro: skip $g $c (MICRO_SKIP)" >&2; continue;; esac
    t0=$(python3 -c 'import time; print(time.time())'); "$b" >/dev/null
    if [ -n "${MICRO_MAX_S:-}" ] && python3 -c "import time,sys; sys.exit(0 if time.time()-$t0 > ${MICRO_MAX_S} else 1)"; then
      echo "micro: skip $g $c (warm-up over MICRO_MAX_S=${MICRO_MAX_S}s)" >&2; continue
    fi
    run="$run $g"
  done
  for r in 1 2 3 4 5; do
    for g in $run; do eval "ts_$g=\"\$ts_$g \$(../compiler/build/gcmicro/$g.$c | grep -oE 'nanos=[0-9]+' | cut -d= -f2)\""; done
  done
  for g in $run; do
    b=../compiler/build/gcmicro/$g.$c; eval "ts=\$ts_$g"
    python3 -c "v=sorted(map(int,'$ts'.split()))[1:4]; print('$c', round(sum(v)/3/1e6, 3))" >> results/gc/micro-$g-time.txt
    rss=$( { /usr/bin/time -l "$b" >/dev/null; } 2>&1 | awk '/maximum resident set size/ {print $1}')
    echo "$c $(python3 -c "print(round($rss/1048576, 1))")" >> results/gc/micro-$g-rss.txt
    st=$(KX_GC_STATS=1 "$b" 2>&1 >/dev/null | grep '^gc-stats:')
    for m in collections pause_total pause_max pause_p50 pause_p99; do
      echo "$c $(echo "$st" | grep -oE "$m=[0-9.]+" | cut -d= -f2)" >> results/gc/micro-$g-$m.txt
    done
    v() { awk -v c="$c" '$1 == c {print $2}' "results/gc/micro-$g-$1.txt"; }
    python3 record.py gc-micro "$c" --run "micro-$g" --gc "$g" ms="$(v time)" raw_ns="$(echo $ts | tr ' ' ',')" \
      peak_rss_mib="$(v rss)" pause_total_ms="$(v pause_total)" pause_max_ms="$(v pause_max)" pause_p50_ms="$(v pause_p50)" pause_p99_ms="$(v pause_p99)" collections="$(v collections)"
  done
done
for m in time:"case, ms" rss:"case, peak RSS MiB" pause_total:"case, total GC pause ms" pause_p50:"case, p50 GC pause ms" pause_p99:"case, p99 GC pause ms" pause_max:"case, max GC pause ms" collections:"case, collections"; do
  k=${m%%:*}; args=""; for g in $gcs; do args="$args $g=results/gc/micro-$g-$k.txt"; done
  python3 gc/table.py --metric "${m#*:}" $args; echo
done | tee results/gc/micro-table.md
