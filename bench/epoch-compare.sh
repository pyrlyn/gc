#!/bin/bash
# Epoch GC branch vs main trees, epoch GC only:
#   bench/gc/epoch-compare.sh <out-dir> label=<tree>[:ENV=VAL,...] ...
# e.g. main-2c9e4a9=../kotlinx-ix-2c9e4a9 main-ded919f=../kotlinx-ix-ded919f branch=. off=.:KX_GC_X=0 (CASES overrides the case list)
# Every tree needs a built compiler. Cases: the micro benchmarks huge/wide_graph/big_live_churn and the nkbench cases lru,
# cycles, bigheap, each compiled with --gc=epoch by its own tree. Interleaved like micro.sh / compare.sh:
# ROUNDS (default 3) rounds, each a warm-up + 5 timed runs per variant (mean of the middle 3), in rotated
# order; plus one /usr/bin/time -l peak RSS run per variant and round. Reported: median over rounds.
# One file per benchmark: <out-dir>/<case>.txt (raw per-round values and the medians).
set -eu
out=$1; shift; mkdir -p "$out"; out=$(cd "$out" && pwd)
rounds=${ROUNDS:-3}
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$here/bench/data/words.txt" ] || (cd "$here/bench" && python3 gen_data.py >/dev/null)
tmp=$(mktemp -d "${BENCH_TMP:-${TMPDIR:-/tmp}}/epoch-compare.XXXXXX")
labels=(); for spec in "$@"; do labels+=("${spec%%=*}"); done
src_of() { case $1 in *_churn) echo bench/gc/micro/$1.kt;; *) echo bench/cases/$1/kotlin/Main.kt;; esac; }
envs_of() { local s=${1#*=}; case $s in *:*) echo "${s#*:}" | tr ',' ' ';; esac; }
tree_of() { local s=${1#*=}; s=${s%%:*}; (cd "$s" && pwd); }
for c in ${CASES:-huge_live_churn wide_graph_churn big_live_churn lru cycles bigheap}; do
  f=$out/$c.txt
  echo "# $c, epoch GC, $(date '+%F %T %z'), rounds=$rounds, load $(sysctl -n vm.loadavg)" > "$f"
  for spec in "$@"; do
    l=${spec%%=*}; t=$(tree_of "$spec")
    echo "# $l: $(git -C "$t" rev-parse --short HEAD)$(git -C "$t" diff --quiet || echo +dirty) env: $(envs_of "$spec")" >> "$f"
    "$t/bin/newkotlinc" --gc=epoch "$t/$(src_of $c)" -o "$tmp/$l.$c" >/dev/null
  done
  specs=("$@")
  for r in $(seq 1 "$rounds"); do
    n=${#specs[@]}
    for i in $(seq 0 $((n - 1))); do
      spec=${specs[$(( (i + r - 1) % n ))]}; l=${spec%%=*}; b=$tmp/$l.$c
      e=$(envs_of "$spec")
      (cd "$here/bench" && env $e BENCH_DATA=data/words.txt "$b" >/dev/null)
      ts=""; for k in 1 2 3 4 5; do ts="$ts $(cd "$here/bench" && env $e BENCH_DATA=data/words.txt "$b" | grep -oE 'nanos=[0-9]+' | cut -d= -f2)"; done
      ms=$(python3 -c "v=sorted(map(int,'$ts'.split()))[1:4]; print(round(sum(v)/3/1e6, 3))")
      rss=$( { cd "$here/bench" && env $e BENCH_DATA=data/words.txt /usr/bin/time -l "$b" >/dev/null; } 2>&1 | awk '/maximum resident set size/ {print $1}')
      echo "round $r $l ms=$ms rss_mib=$(python3 -c "print(round($rss/1048576, 1))") raw_ns=$(echo $ts | tr ' ' ',')" >> "$f"
    done
  done
  python3 - "$f" "${labels[@]}" <<'PY'
import sys, statistics, re
f, labels = sys.argv[1], sys.argv[2:]
rows = [l.split() for l in open(f) if l.startswith("round ")]
with open(f, "a") as o:
    for lab in labels:
        ms = [float(r[3][3:]) for r in rows if r[2] == lab]; rss = [float(r[4][8:]) for r in rows if r[2] == lab]
        o.write(f"median {lab} ms={round(statistics.median(ms), 3)} rss_mib={round(statistics.median(rss), 1)}\n")
PY
  grep '^median' "$f"
done
rm -rf "$tmp"
