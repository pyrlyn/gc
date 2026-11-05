#!/bin/bash
# GC tests (separate from feature and upstream tests). For every implementation in compiler/gc/*/gc.c
# (or $GCS, e.g. GCS="perceus rc"), according to its caps file
# (cycles = reclaims unreachable cycles, precise = live object count is exact at exit, asan = ASan-compatible):
#   1. unit/gc_unit.c: C tests of the kxgc.h interface (built with clang, -O1 and -O3).
#   2. kt/*.kt: GC-agnostic Kotlin tests; stdout must equal <name>.out. Tests marked "// gc-needs: cycles"
#      are skipped for implementations without the cycles capability.
#      precise: a --leak-check build must report zero live objects. asan: an ASan build (--alloc malloc) must pass.
set -u
cd "$(dirname "$0")/../../../.."
NKC=${NKC:-compiler/build/newkotlinc.kexe}
[ -x "$NKC" ] || compiler/build.sh >/dev/null
CC=${NK_CC:-$( [ -x /usr/bin/clang ] && echo /usr/bin/clang || echo clang )}
gcs=${GCS:-$(for d in compiler/gc/*/gc.c; do basename "$(dirname "$d")"; done)}
out=compiler/build/gc-tmp; rm -rf "$out"; mkdir -p "$out"; fail=0
for g in $gcs; do
  caps=$(cat "compiler/gc/$g/caps" 2>/dev/null)
  has() { case " $caps " in *" $1 "*) return 0;; esac; return 1; }
  extra=""; if [ -f "compiler/gc/$g/config.sh" ]; then extra=$(sh "compiler/gc/$g/config.sh") || { echo "FAIL gc $g: config.sh"; fail=1; continue; }; fi
  def=""; has cycles && def=-DKX_CAP_CYCLES; has precise && def="$def -DKX_CAP_PRECISE"
  # The unit test drives the immediate-RC header protocol directly; deferred-RC GCs (epoch) take
  # reference operations through a log instead and are covered by the Kotlin tests below.
  for o in -O1 -O3; do
    if has deferred; then echo "SKIP gc-unit $g $o (deferred RC)"; continue; fi
    if eval "$CC" $o -g -Icompiler/gc $def $extra compiler/gc/tests/archive/unit/gc_unit.c compiler/runtime/runtime.c "compiler/gc/$g/gc.c" -o "$out/unit-$g" 2>"$out/unit-$g.err" \
       && "$out/unit-$g" >"$out/unit-$g.log" 2>&1; then echo "PASS gc-unit $g $o"
    else echo "FAIL gc-unit $g $o"; cat "$out/unit-$g.err" "$out/unit-$g.log" 2>/dev/null | head -20; fail=1; fi
    if [ "$g" = perceus ] || [ "$g" = incremental ]; then
      testdef=""; [ "$g" = incremental ] && testdef=-DTEST_INCREMENTAL
      if "$CC" $o -g -Icompiler/gc $testdef compiler/gc/tests/archive/unit/traversal.c compiler/runtime/runtime.c -o "$out/traversal-$g" 2>"$out/traversal-$g.err" \
         && "$out/traversal-$g" >"$out/traversal-$g.log" 2>&1; then echo "PASS gc-traversal $g $o"
      else echo "FAIL gc-traversal $g $o"; cat "$out/traversal-$g.err" "$out/traversal-$g.log" 2>/dev/null | head -20; fail=1; fi
    fi
  done
  if [ "$g" = perceus ] || [ "$g" = incremental ]; then
    testdef=""; [ "$g" = incremental ] && testdef=-DTEST_INCREMENTAL
    if "$CC" -O1 -g -fsanitize=address -fno-omit-frame-pointer -DRT_PLAIN_MALLOC -Icompiler/gc $testdef \
       compiler/gc/tests/archive/unit/traversal.c compiler/runtime/runtime.c -o "$out/traversal-$g.asan" 2>"$out/traversal-$g.asanerr" \
       && "$out/traversal-$g.asan" >"$out/traversal-$g.asanlog" 2>&1; then echo "PASS gc-traversal-asan $g"
    else echo "FAIL gc-traversal-asan $g"; cat "$out/traversal-$g.asanerr" "$out/traversal-$g.asanlog" 2>/dev/null | head -20; fail=1; fi
  fi
  for t in compiler/gc/tests/kt/*.kt; do
    n=$(basename "$t" .kt); exp=$(cat "compiler/gc/tests/kt/$n.out")
    if grep -q '^// gc-needs: cycles' "$t" && ! has cycles; then echo "SKIP gc $g $n (no cycle collection)"; continue; fi
    if "$NKC" --gc="$g" "$t" -o "$out/$g.$n" 2>"$out/$g.$n.err" && [ "$("$out/$g.$n" 2>&1)" = "$exp" ]; then echo "PASS gc $g $n"
    else echo "FAIL gc $g $n"; head -5 "$out/$g.$n.err"; fail=1; fi
    if has precise; then
      "$NKC" --gc="$g" --leak-check "$t" -o "$out/$g.$n.lc" 2>/dev/null; got=$("$out/$g.$n.lc" 2>"$out/$g.$n.lcerr"); rc=$?
      if [ $rc -eq 0 ] && [ "$got" = "$exp" ] && grep -q "leak-check: OK" "$out/$g.$n.lcerr"; then echo "PASS gc-leaks $g $n"
      else echo "FAIL gc-leaks $g $n (rc=$rc)"; grep -v "live=0" "$out/$g.$n.lcerr" | head; fail=1; fi
    fi
    if has asan; then
      "$NKC" --gc="$g" --alloc malloc --cflags "-O1 -g -fsanitize=address -fno-omit-frame-pointer" "$t" -o "$out/$g.$n.asan" 2>/dev/null
      got=$("$out/$g.$n.asan" 2>"$out/$g.$n.asanerr"); rc=$?
      if [ $rc -eq 0 ] && [ "$got" = "$exp" ]; then echo "PASS gc-asan $g $n"; else echo "FAIL gc-asan $g $n (rc=$rc)"; head -20 "$out/$g.$n.asanerr"; fail=1; fi
    fi
  done
done
# Epoch: a back-pressure wait over the pause target on every hand-off (KX_GC_TARGET_PAUSE_US=1, i.e. a
# collector that is always late) must not grow the log queue / log pool without bound: the adaptive limit
# stays <= 16 and at most limit + 2 spare logs are kept (it used to reach 64 logs, 2x peak RSS).
if [[ " $(echo $gcs) " == *" epoch "* ]]; then
  t=compiler/gc/tests/epoch/queue_spike.kt
  if "$NKC" --gc=epoch "$t" -o "$out/epoch.queue_spike" 2>/dev/null; then
    dbg=$(KX_GC_TARGET_PAUSE_US=1 KX_GC_DEBUG=1 "$out/epoch.queue_spike" 2>&1 >/dev/null)
    q=$(echo "$dbg" | grep -oE 'qmax=[0-9]+' | cut -d= -f2); logs=$(echo "$dbg" | grep -oE 'mem MiB slabs=[0-9.]+ logs=[0-9]+' | grep -oE '[0-9]+$')
    if [ -n "$q" ] && [ -n "$logs" ] && [ "$q" -le 16 ] && [ "$logs" -le 20 ]; then echo "PASS gc-epoch queue_spike (qmax=$q logs=$logs)"
    else echo "FAIL gc-epoch queue_spike (qmax=$q logs=$logs, want <= 16 / <= 20)"; fail=1; fi
  else echo "FAIL gc-epoch queue_spike: compile"; fail=1; fi
fi
# Epoch: with KX_GC_BOUNDARY_KEEP=16384 (default 0) most dead objects are freed by traced allocations (paced),
# not inside the boundary pause; KX_GC_BOUNDARY_KEEP=0 restores freeing at the boundary. Both must free
# everything (--leak-check) and print the same checksum.
if [[ " $(echo $gcs) " == *" epoch "* ]]; then
  t=compiler/gc/tests/epoch/paced_free.kt; want="checksum=2000001000000"
  if "$NKC" --gc=epoch "$t" -o "$out/epoch.paced" 2>/dev/null && "$NKC" --gc=epoch --leak-check "$t" -o "$out/epoch.paced.lc" 2>/dev/null; then
    dbg=$(KX_GC_BOUNDARY_KEEP=16384 KX_GC_DEBUG=1 KX_GC_EXIT_DRAIN=1 "$out/epoch.paced" 2>&1); got=$(echo "$dbg" | grep '^checksum=')
    pc=$(echo "$dbg" | grep -oE 'freed paced=[0-9]+' | grep -oE '[0-9]+$'); bf=$(echo "$dbg" | grep -oE 'freed paced=[0-9]+ boundary=[0-9]+' | grep -oE '[0-9]+$')
    if [ "$got" = "$want" ] && [ -n "$pc" ] && [ -n "$bf" ] && [ "$pc" -gt "$bf" ]; then echo "PASS gc-epoch paced_free (paced=$pc boundary=$bf)"
    else echo "FAIL gc-epoch paced_free (got=$got paced=$pc boundary=$bf, want paced > boundary)"; fail=1; fi
    for keep in 16384 0; do
      got=$(KX_GC_BOUNDARY_KEEP=$keep "$out/epoch.paced.lc" 2>"$out/epoch.paced.lcerr"); rc=$?
      if [ $rc -eq 0 ] && [ "$got" = "$want" ] && grep -q "leak-check: OK" "$out/epoch.paced.lcerr"; then echo "PASS gc-epoch paced_free leaks keep=$keep"
      else echo "FAIL gc-epoch paced_free leaks keep=$keep (rc=$rc)"; head "$out/epoch.paced.lcerr"; fail=1; fi
    done
  else echo "FAIL gc-epoch paced_free: compile"; fail=1; fi
fi
# Epoch: freed big blocks are released with madvise (madvised > 0), KX_GC_MADVISE=0 turns it off, and
# both free everything with the same checksum.
if [[ " $(echo $gcs) " == *" epoch "* ]]; then
  t=compiler/gc/tests/epoch/madvise_big.kt; want="checksum=800000"
  if "$NKC" --gc=epoch "$t" -o "$out/epoch.madv" 2>/dev/null && "$NKC" --gc=epoch --leak-check "$t" -o "$out/epoch.madv.lc" 2>/dev/null; then
    for m in 1 0; do
      dbg=$(KX_GC_MADVISE=$m KX_GC_DEBUG=1 KX_GC_EXIT_DRAIN=1 "$out/epoch.madv" 2>&1); got=$(echo "$dbg" | grep '^checksum=')
      mv=$(echo "$dbg" | grep -oE 'madvised=[0-9]+' | grep -oE '[0-9]+$')
      ok=0; if [ -n "$mv" ]; then if [ $m = 1 ]; then [ "$mv" -gt 0 ] && ok=1; else [ "$mv" -eq 0 ] && ok=1; fi; fi
      if [ "$got" = "$want" ] && [ $ok = 1 ]; then echo "PASS gc-epoch madvise_big madvise=$m (madvised=$mv)"
      else echo "FAIL gc-epoch madvise_big madvise=$m (got=$got madvised=$mv)"; fail=1; fi
      got=$(KX_GC_MADVISE=$m "$out/epoch.madv.lc" 2>"$out/epoch.madv.lcerr"); rc=$?
      if [ $rc -eq 0 ] && [ "$got" = "$want" ] && grep -q "leak-check: OK" "$out/epoch.madv.lcerr"; then echo "PASS gc-epoch madvise_big leaks madvise=$m"
      else echo "FAIL gc-epoch madvise_big leaks madvise=$m (rc=$rc)"; head "$out/epoch.madv.lcerr"; fail=1; fi
    done
  else echo "FAIL gc-epoch madvise_big: compile"; fail=1; fi
fi
# Incremental: a live root scanned black by an earlier slice must leave the buffer with the step that stopped
# there. Left behind, a later step frees it in the middle of its own release (double free under ASan).
if [[ " $(echo $gcs) " == *" incremental "* ]]; then
  t=compiler/gc/tests/incremental/slice_black.kt
  if "$NKC" --gc=incremental --alloc malloc --cflags "-O1 -g -fsanitize=address -fno-omit-frame-pointer" "$t" -o "$out/incremental.slice_black" 2>/dev/null; then
    got=$(KX_GC_BUDGET_US=300 "$out/incremental.slice_black" 2>"$out/incremental.slice_black.err"); rc=$?
    if [ $rc -eq 0 ] && [ "$got" = "53215861" ]; then echo "PASS gc-incremental slice_black"
    else echo "FAIL gc-incremental slice_black (rc=$rc)"; head -20 "$out/incremental.slice_black.err"; fail=1; fi
  else echo "FAIL gc-incremental slice_black: compile"; fail=1; fi
  # A step over budget on its first slice finishes in one pass instead of re-tracing a shared graph per slice.
  t=compiler/gc/tests/archive/incremental/one_pass.c
  if "$CC" -O1 -g -Icompiler/gc "$t" compiler/runtime/runtime.c compiler/gc/incremental/gc.c -o "$out/incremental.one_pass" 2>"$out/incremental.one_pass.err" \
     && KX_GC_BUDGET_US=0 "$out/incremental.one_pass" 2>>"$out/incremental.one_pass.err"; then echo "PASS gc-incremental one_pass"
  else echo "FAIL gc-incremental one_pass"; head -20 "$out/incremental.one_pass.err"; fail=1; fi
fi
# Selecting an unknown implementation is a compile error.
if "$NKC" --gc=nope compiler/gc/tests/kt/reuse.kt -o "$out/nope" 2>/dev/null; then echo "FAIL gc-unknown"; fail=1; else echo "PASS gc-unknown"; fi
rm -rf "$out"
[ $fail -eq 0 ] && echo "GC ALL PASSED" || { echo "GC FAILED"; exit 1; }
