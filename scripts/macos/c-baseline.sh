#!/bin/bash
# Build and run the original unchanged C collectors on this Mac.
# Does not edit perceus/incremental/epoch/rc C sources.
# Writes artifacts/macos-local/c/ — never overwrites the frozen Linux VM baseline.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="$ROOT/artifacts/c-baseline/host/kx_runtime_host.c"
OUT="$ROOT/artifacts/macos-local/c/out"
LOG="$ROOT/artifacts/macos-local/c/logs"
mkdir -p "$OUT" "$LOG"
CC="${NK_CC:-clang}"
OPT="${OPT:--O3 -flto}"
N="${N:-4000000}"
ROUNDS="${ROUNDS:-5}"
GCS="${GCS:-perceus incremental epoch rc}"

{
  echo "=== macOS C baseline (local Mac; not a cloud VM) ==="
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repo=$ROOT"
  echo "git_sha=$(git -C "$ROOT" rev-parse HEAD)"
  echo "uname=$(uname -a)"
  echo "hw=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
  echo "ncpu=$(sysctl -n hw.ncpu)"
  echo "cc=$CC"
  echo "cc_version=$($CC --version | head -1)"
  echo "opt=$OPT"
  echo "ops_N=$N"
  echo "ops_rounds=$ROUNDS"
  echo "host_runtime=$HOST"
  echo "clock=clock_gettime_nsec_np(CLOCK_UPTIME_RAW)"
  echo "c_sources_frozen_sha=21f34a960f8b56d1dcdf1ab55b8e5e14e4e8ff31"
  echo "note=Kotlin micro.sh/compare.sh not run (no newkotlinc)"
} | tee "$LOG/environment.txt"

compile() {
  local g="$1" extra=""
  if [ -f "$ROOT/$g/config.sh" ]; then extra=$(bash "$ROOT/$g/config.sh"); fi
  if grep -qw deferred "$ROOT/$g/caps" 2>/dev/null; then extra="$extra -DDEFERRED"; fi
  echo "COMPILE $g $CC $OPT -I$ROOT $extra" | tee -a "$LOG/compile.txt"
  # shellcheck disable=SC2086
  $CC $OPT -g -I"$ROOT" $extra \
    "$ROOT/bench/ops/ops.c" "$HOST" "$ROOT/$g/gc.c" \
    -o "$OUT/ops.$g" -lpthread
}

compile_unit() {
  local g="$1" o="$2" def="" extra=""
  local caps
  caps=$(cat "$ROOT/$g/caps")
  case " $caps " in *" cycles "*) def="$def -DKX_CAP_CYCLES";; esac
  case " $caps " in *" precise "*) def="$def -DKX_CAP_PRECISE";; esac
  if [ -f "$ROOT/$g/config.sh" ]; then extra=$(bash "$ROOT/$g/config.sh"); fi
  # shellcheck disable=SC2086
  $CC $o -g -I"$ROOT" $def $extra \
    "$ROOT/tests/archive/unit/gc_unit.c" "$HOST" "$ROOT/$g/gc.c" \
    -o "$OUT/unit-$g$o" -lpthread
}

compile_trav() {
  local g="$1" o="$2" testdef=""
  [ "$g" = incremental ] && testdef=-DTEST_INCREMENTAL
  # traversal.c includes ../../perceus/gc.c (kotlinx layout). Copy like the VM runner.
  local tmp
  tmp=$(mktemp -d)
  cp "$ROOT/tests/archive/unit/traversal.c" "$tmp/traversal.c"
  mkdir -p "$tmp/perceus" "$tmp/incremental"
  cp "$ROOT/perceus/gc.c" "$tmp/perceus/gc.c"
  cp "$ROOT/incremental/gc.c" "$tmp/incremental/gc.c"
  # shellcheck disable=SC2086
  $CC $o -g -I"$ROOT" $testdef "$tmp/traversal.c" "$HOST" -o "$OUT/trav-$g$o" -lpthread
  rm -rf "$tmp"
}

echo "=== compile ==="
for g in $GCS; do compile "$g"; done
for g in perceus incremental rc; do
  for o in -O1 -O3; do compile_unit "$g" "$o"; done
done
for g in perceus incremental; do
  for o in -O1 -O3; do compile_trav "$g" "$o"; done
done
$CC -O1 -g -I"$ROOT" "$ROOT/tests/archive/incremental/one_pass.c" \
  "$HOST" "$ROOT/incremental/gc.c" -o "$OUT/one_pass" -lpthread

echo "=== C unit tests ==="
{
  fail=0
  for g in perceus incremental rc; do
    for o in -O1 -O3; do
      if "$OUT/unit-$g$o" >"$LOG/unit-$g$o.log" 2>&1; then
        echo "PASS gc-unit $g $o"
      else
        echo "FAIL gc-unit $g $o"; tail -20 "$LOG/unit-$g$o.log"; fail=1
      fi
    done
  done
  echo "SKIP gc-unit epoch (deferred RC; same as archive/run.sh)"
  for g in perceus incremental; do
    for o in -O1 -O3; do
      if "$OUT/trav-$g$o" >"$LOG/trav-$g$o.log" 2>&1; then
        echo "PASS gc-traversal $g $o"
      else
        echo "FAIL gc-traversal $g $o"; tail -20 "$LOG/trav-$g$o.log"; fail=1
      fi
    done
  done
  if KX_GC_BUDGET_US=0 "$OUT/one_pass" >"$LOG/one_pass.log" 2>&1; then
    echo "PASS gc-incremental one_pass"
  else
    echo "FAIL gc-incremental one_pass"; cat "$LOG/one_pass.log"; fail=1
  fi
  echo "unit_fail=$fail"
} | tee "$LOG/unit-summary.txt"

echo "=== ops (N=$N, ROUNDS=$ROUNDS, GCs interleaved) ==="
{
  echo "# start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# N=$N"
  echo "## N=$N"
  for r in $(seq "$ROUNDS"); do
    echo "# round $r"
    for g in $GCS; do
      "$OUT/ops.$g" "$N" | sed "s/^[^ ]*/$g/"
    done
  done
  echo "# end $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$LOG/ops-raw.txt"

echo "=== size sweep ==="
{
  for n in 100000 1000000 4000000; do
    echo "## N=$n"
    for r in 1 2 3; do
      for g in $GCS; do
        echo -n "N=$n round=$r "
        "$OUT/ops.$g" "$n"
      done
    done
  done
} | tee "$LOG/ops-size-sweep.txt"

echo "=== peak RSS via /usr/bin/time -l (Darwin maxrss is bytes) ==="
{
  for g in $GCS; do
    echo "## $g"
    /usr/bin/time -l "$OUT/ops.$g" "$N" 2>&1
  done
} | tee "$LOG/ops-rss.txt"

{
  git -C "$ROOT" rev-parse HEAD
  shasum -a 256 "$ROOT/kxgc.h" "$ROOT/common/"*.inc "$ROOT/"*/gc.c "$ROOT/bench/ops/ops.c"
} | tee "$LOG/source-hashes.txt"

echo "macOS C baseline complete. Logs in $LOG"
echo "These numbers are local Mac only if this script ran on a Mac."
