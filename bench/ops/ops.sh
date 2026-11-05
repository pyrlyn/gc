#!/bin/bash
# Per-operation mutator cost (ns/op, median of 5) of each GC for the shapes in ops.c; GCs interleaved,
# ROUNDS (default 5) rounds, median per op over rounds. ./ops.sh [gc ...] (default: epoch perceus boehm)
set -eu
cd "$(dirname "$0")"; C=../../../compiler; out=${OUT:-$C/build/gc-ops}; mkdir -p "$out"
cc=${NK_CC:-clang}; gcs=${*:-epoch perceus boehm}
for g in $gcs; do
  extra=""; [ -f "$C/gc/$g/config.sh" ] && extra=$(bash "$C/gc/$g/config.sh")
  grep -qw deferred "$C/gc/$g/caps" && extra="$extra -DDEFERRED"
  eval "$cc" -O3 -flto -I"$C/gc" $extra ops.c "$C/runtime/runtime.c" "$C/gc/$g/gc.c" -o "$out/ops.$g" -lpthread
done
echo "# load: $(sysctl -n vm.loadavg 2>/dev/null || cat /proc/loadavg)"
for r in $(seq ${ROUNDS:-5}); do for g in $gcs; do "$out/ops.$g" ${N:-4000000} ${OP:-} | sed "s/^[^ ]*/$g/"; done; done | python3 -c '
import sys, statistics as s, collections as c
d = c.defaultdict(list)
for l in sys.stdin: g, op, v = l.split(); d[(op, g)].append(float(v))
gcs = list(dict.fromkeys(g for _, g in d)); ops = list(dict.fromkeys(o for o, _ in d))
print("| op (ns/op) | " + " | ".join(gcs) + " |"); print("|---|" + "---:|" * len(gcs))
for o in ops: print("| " + o + " | " + " | ".join("%.2f" % s.median(d[(o, g)]) for g in gcs) + " |")'
