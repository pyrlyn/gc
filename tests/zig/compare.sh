#!/bin/bash
# Verifies that the Zig GC suite is a faithful port of compiler/gc/tests/archive/run.sh:
#   1. runs run.sh and `zig build ported` (sequentially) and diffs their full output and exit codes
#      byte for byte, after masking only the timing-dependent counters listed in MASK below;
#   2. builds every C unit test and its Zig port with the same compiler/flags for each collector and
#      diffs their stdout and exit codes, masking only pause times.
# Results go to $OUT (default compiler/build/gc-compare): raw outputs, masked outputs and diffs.
# Usage: compiler/gc/tests/zig/compare.sh   (GCS=... restricts collectors, as for run.sh)
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../../../.." && pwd)"; cd "$root"
OUT=${OUT:-compiler/build/gc-compare}; rm -rf "$OUT"; mkdir -p "$OUT"
CC=${NK_CC:-$( [ -x /usr/bin/clang ] && echo /usr/bin/clang || echo clang )}
# Timing-dependent values (each suite still asserts its own bounds on them):
#   paced=/boundary= how many dead objects were freed paced vs at the boundary (depends on collector speed)
#   qmax=/logs=      peak log queue / pool size under back-pressure (bounded: <= 16 / <= 20)
#   madvised=        bytes handed back with madvise (> 0 or == 0 asserted)
#   pause_*          collector pause times
MASK='s/(paced|boundary|qmax|logs|madvised|pause_max_us|pause_total_ns|pause_max_ns)=[0-9]+/\1=N/g'
fail=0

echo "== suite: run.sh vs zig build ported"
bash compiler/gc/tests/archive/run.sh >"$OUT/run.sh.out" 2>&1; echo "exit=$?" >>"$OUT/run.sh.out"
(cd "$here" && zig build ported) >"$OUT/zig.out" 2>&1; echo "exit=$?" >>"$OUT/zig.out"
sed -E "$MASK" "$OUT/run.sh.out" >"$OUT/run.sh.masked"; sed -E "$MASK" "$OUT/zig.out" >"$OUT/zig.masked"
if cmp -s "$OUT/run.sh.masked" "$OUT/zig.masked"; then echo "IDENTICAL ($(grep -c '' "$OUT/zig.out") lines; raw diff below is masked values only)"
else echo "DIFFERENT:"; diff "$OUT/run.sh.masked" "$OUT/zig.masked"; fail=1; fi
diff "$OUT/run.sh.out" "$OUT/zig.out" >"$OUT/suite.rawdiff"; cat "$OUT/suite.rawdiff"

echo "== unit programs: C original vs Zig port (stdout + exit code)"
obj="$here/zig-out/obj"
gcs=${GCS:-$(for d in compiler/gc/*/gc.c; do basename "$(dirname "$d")"; done)}
# Per-collector extra masks for the unit programs' final stats line (not printed by run.sh, which only checks
# the exit code): incremental's collection count depends on its time budget (KX_GC_BUDGET_US slices; the C
# binary alone varies run to run).
unit_mask() { case "$1" in *incremental*) echo 's/collections=[0-9]+/collections=N/';; *) echo 's/^$//';; esac; }
cmpbin() { # name, C binary, Zig binary, env, args for C, args for Zig
  local n=$1 cb=$2 zb=$3 e=$4 ca=$5 za=$6 m; m=$(unit_mask "$n")
  env $e "$cb" $ca >"$OUT/$n.c.out" 2>&1; echo "exit=$?" >>"$OUT/$n.c.out"
  env $e "$zb" $za >"$OUT/$n.zig.out" 2>&1; echo "exit=$?" >>"$OUT/$n.zig.out"
  # Line numbers in a failure message differ by file; none are printed on success.
  if diff <(sed -E "$MASK;$m" "$OUT/$n.c.out") <(sed -E "$MASK;$m" "$OUT/$n.zig.out") >"$OUT/$n.diff"; then
    echo "IDENTICAL $n: $(tr '\n' ' ' <"$OUT/$n.zig.out")"
  else echo "DIFFERENT $n"; cat "$OUT/$n.diff"; fail=1; fi
}
for g in $gcs; do
  caps=$(cat "compiler/gc/$g/caps" 2>/dev/null); has() { case " $caps " in *" $1 "*) return 0;; esac; return 1; }
  extra=""; [ -f "compiler/gc/$g/config.sh" ] && extra=$(sh "compiler/gc/$g/config.sh")
  def=""; zargs=""; has cycles && { def=-DKX_CAP_CYCLES; zargs=cycles; }; has precise && { def="$def -DKX_CAP_PRECISE"; zargs="$zargs precise"; }
  for o in -O1 -O3; do
    if ! has deferred; then
      eval "$CC" $o -g -Icompiler/gc $def $extra compiler/gc/tests/archive/unit/gc_unit.c compiler/runtime/runtime.c "compiler/gc/$g/gc.c" -o "$OUT/unit-$g$o.c" 2>/dev/null
      eval "$CC" $o -g -Icompiler/gc $def $extra "$obj/gc_unit.o" compiler/runtime/runtime.c "compiler/gc/$g/gc.c" -o "$OUT/unit-$g$o.zig" 2>/dev/null
      cmpbin "gc_unit-$g$o" "$OUT/unit-$g$o.c" "$OUT/unit-$g$o.zig" "" "" "$zargs"
    fi
    if [ "$g" = perceus ] || [ "$g" = incremental ]; then
      td=""; [ "$g" = incremental ] && td=-DTEST_INCREMENTAL
      "$CC" $o -g -Icompiler/gc $td compiler/gc/tests/archive/unit/traversal.c compiler/runtime/runtime.c -o "$OUT/trav-$g$o.c" 2>/dev/null
      "$CC" $o -g -Icompiler/gc $td "$obj/traversal.o" compiler/gc/tests/zig/src/unit/traversal_shim.c compiler/runtime/runtime.c -o "$OUT/trav-$g$o.zig" 2>/dev/null
      cmpbin "traversal-$g$o" "$OUT/trav-$g$o.c" "$OUT/trav-$g$o.zig" "" "" ""
    fi
  done
  if [ "$g" = incremental ]; then
    "$CC" -O1 -g -Icompiler/gc compiler/gc/tests/archive/incremental/one_pass.c compiler/runtime/runtime.c compiler/gc/incremental/gc.c -o "$OUT/one_pass.c" 2>/dev/null
    "$CC" -O1 -g -Icompiler/gc "$obj/one_pass.o" compiler/runtime/runtime.c compiler/gc/incremental/gc.c -o "$OUT/one_pass.zig" 2>/dev/null
    cmpbin one_pass "$OUT/one_pass.c" "$OUT/one_pass.zig" KX_GC_BUDGET_US=0 "" ""
  fi
done
[ $fail -eq 0 ] && echo "COMPARE: IDENTICAL" || { echo "COMPARE: DIFFERENT"; exit 1; }
