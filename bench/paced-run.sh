#!/bin/bash
# One isolated measurement run for the paced-freeing experiment (gc-improvement-experiment).
#   bench/gc/paced-run.sh <tree> <out-dir>
# In <tree> (a kotlinx checkout with a built compiler): the full GC test suite (zig build ported in compiler/gc/tests/zig),
# then bench/gc/micro.sh epoch perceus, then one KX_GC_DEBUG=1 run per epoch micro benchmark (collector
# scratch memory, boundary max, freed paced/boundary). Writes one file per benchmark to <out-dir>:
#   gc-tests.txt, micro-table.md, micro-<bench>.txt. Run with no other heavy processes.
set -u
tree=$(cd "$1" && pwd); out=$2; mkdir -p "$out"; out=$(cd "$out" && pwd)
cd "$tree"
{ echo "commit $(git rev-parse --short HEAD) $(date '+%F %T %z') load $(sysctl -n vm.loadavg)"; (cd compiler/gc/tests/zig && zig build ported); } > "$out/gc-tests.txt" 2>&1
bench/gc/micro.sh epoch perceus > /dev/null 2>&1
cp bench/results/gc/micro-table.md "$out/micro-table.md"
for src in bench/gc/micro/*.kt; do
  c=$(basename "$src" .kt); f="$out/micro-$c.txt"; : > "$f"
  for g in epoch perceus; do
    for m in time rss pause_total pause_max collections; do
      echo "$g $m $(awk -v c="$c" '$1 == c {print $2}' "bench/results/gc/micro-$g-$m.txt")" >> "$f"
    done
  done
  KX_GC_DEBUG=1 compiler/build/gcmicro/epoch."$c" 2>&1 >/dev/null | grep -E 'boundary max|freed paced|mem MiB slabs|exit live' >> "$f"
done
echo "done $out"
