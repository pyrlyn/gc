#!/bin/sh
# Lock-removal mutants for the multithreaded test: removes each `pthread_mutex_lock(&mu);` in epoch/gc.c in
# turn and runs src/unit/mt_test.zig like the runner does (plain -O1 and TSan, incremental and stop-the-world
# majors, KX_GC_LOCK_CHECK). A mutant is caught when any run fails. Needs `zig build install` first.
# usage: compiler/gc/tests/zig/mutation/mt_locks.sh [scratch dir]   (from the repository root)
set -u
D=${1:-compiler/build/gc-mt-locks}; rm -rf "$D"; mkdir -p "$D/epoch"; ln -s "$PWD/compiler/gc/common" "$D/common"
Z=compiler/gc/tests/zig/zig-out/obj/mt_test.o; S=compiler/gc/tests/zig/src/unit/mt_shim.c
B="KX_GC_EXIT_DRAIN=1 KX_GC_THREADS=4 KX_GC_LOG_CAP=256 KX_GC_MIN_THRESHOLD=16 KX_GC_MAJOR_RATIO=1"
export TSAN_OPTIONS=halt_on_error=1:exitcode=66:second_deadlock_stack=1
total=0; caught=0
for L in $(grep -n 'pthread_mutex_lock(&mu);' compiler/gc/epoch/gc.c | cut -d: -f1); do
  awk -v L="$L" 'NR==L{sub(/pthread_mutex_lock\(&mu\);/,"")}1' compiler/gc/epoch/gc.c > "$D/epoch/gc.c"
  clang -O1 -DKX_GC_LOCK_CHECK -g -Icompiler/gc $Z $S compiler/runtime/runtime.c "$D/epoch/gc.c" -o "$D/p-$L" 2>/dev/null
  clang -O1 -DKX_GC_LOCK_CHECK -fsanitize=thread -fno-omit-frame-pointer -DRT_PLAIN_MALLOC -g -Icompiler/gc $Z $S compiler/runtime/runtime.c "$D/epoch/gc.c" -o "$D/t-$L" 2>/dev/null
  res=""; hit=0
  for b in p t; do for v in "KX_GC_MAJOR_STEP_US=0 KX_GC_MAJOR_STEP=64" "KX_GC_INC_MAJOR=0"; do
    env $B $v timeout 60 "$D/$b-$L" epoch >"$D/$b-$L.log" 2>&1; r=$?; res="$res $b:$r"; [ $r -ne 0 ] && hit=1
  done; done
  total=$((total + 1)); caught=$((caught + hit))
  echo "line $L$res $( [ $hit = 1 ] && echo CAUGHT || echo SURVIVED )"
done
echo "caught $caught/$total"
