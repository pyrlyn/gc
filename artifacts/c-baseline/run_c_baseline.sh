#!/bin/bash
# Run original C collectors/tests/benches AS IS. Does not modify the repo.
# Host-only: kx_runtime_host.c supplies Linux replacements for KotlinX runtime
# symbols (rt_nanos / rt_panic / rt_gc_note_pause / rt_rel_draining / ...).
set -eu
ROOT="${ROOT:-/workspace}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
LOG="$HERE/logs"
mkdir -p "$OUT" "$LOG"

CC="${NK_CC:-clang}"
OPT="${OPT:--O3 -flto}"
N="${N:-4000000}"
ROUNDS="${ROUNDS:-5}"
GCS="${GCS:-perceus incremental epoch rc}"

{
  echo "=== C baseline environment ==="
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repo=$ROOT"
  echo "git_sha=$(git -C "$ROOT" rev-parse HEAD)"
  echo "git_describe=$(git -C "$ROOT" describe --always --dirty)"
  echo "git_status_clean=$(git -C "$ROOT" status --porcelain | wc -l)"
  echo "uname=$(uname -a)"
  echo "os=$(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "nproc=$(nproc)"
  echo "cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
  echo "cpu_mhz=$(grep -m1 'cpu MHz' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
  echo "mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  echo "loadavg=$(cat /proc/loadavg)"
  echo "cc=$CC"
  echo "cc_version=$($CC --version | head -1)"
  echo "opt=$OPT"
  echo "ops_N=$N"
  echo "ops_rounds=$ROUNDS"
  echo "gcs=$GCS"
  echo "host_runtime=$HERE/kx_runtime_host.c"
  echo "note=KotlinX newkotlinc Kotlin benches (micro.sh/compare.sh) are not run: no newkotlinc in this repo"
} | tee "$LOG/environment.txt"

compile() {
  local g="$1" extra=""
  if [ -f "$ROOT/$g/config.sh" ]; then extra=$(bash "$ROOT/$g/config.sh"); fi
  if grep -qw deferred "$ROOT/$g/caps" 2>/dev/null; then extra="$extra -DDEFERRED"; fi
  echo "COMPILE $g $CC $OPT -I$ROOT $extra" | tee -a "$LOG/compile.txt"
  # shellcheck disable=SC2086
  $CC $OPT -g -I"$ROOT" $extra \
    "$ROOT/bench/ops/ops.c" "$HERE/kx_runtime_host.c" "$ROOT/$g/gc.c" \
    -o "$OUT/ops.$g" -lpthread -lm
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
    "$ROOT/tests/archive/unit/gc_unit.c" "$HERE/kx_runtime_host.c" "$ROOT/$g/gc.c" \
    -o "$OUT/unit-$g$o" -lpthread -lm
}

compile_trav() {
  local g="$1" o="$2" testdef=""
  [ "$g" = incremental ] && testdef=-DTEST_INCREMENTAL
  # shellcheck disable=SC2086
  $CC $o -g -I"$ROOT" $testdef \
    "$ROOT/tests/archive/unit/traversal.c" "$HERE/kx_runtime_host.c" \
    -o "$OUT/trav-$g$o" -lpthread -lm
}

echo
echo "=== compile ops binaries ==="
for g in $GCS; do compile "$g"; done

echo
echo "=== compile unit / traversal / one_pass ==="
for g in perceus incremental rc; do
  for o in -O1 -O3; do
    compile_unit "$g" "$o"
  done
done
for g in perceus incremental; do
  for o in -O1 -O3; do
    compile_trav "$g" "$o"
  done
done
$CC -O1 -g -I"$ROOT" "$ROOT/tests/archive/incremental/one_pass.c" \
  "$HERE/kx_runtime_host.c" "$ROOT/incremental/gc.c" \
  -o "$OUT/one_pass" -lpthread -lm

echo
echo "=== C unit tests ==="
{
  fail=0
  for g in perceus incremental rc; do
    for o in -O1 -O3; do
      if "$OUT/unit-$g$o" >"$LOG/unit-$g$o.log" 2>&1; then
        echo "PASS gc-unit $g $o"
      else
        echo "FAIL gc-unit $g $o"; cat "$LOG/unit-$g$o.log" | tail -20; fail=1
      fi
    done
  done
  echo "SKIP gc-unit epoch (deferred RC; same as archive/run.sh)"
  for g in perceus incremental; do
    for o in -O1 -O3; do
      if "$OUT/trav-$g$o" >"$LOG/trav-$g$o.log" 2>&1; then
        echo "PASS gc-traversal $g $o"
      else
        echo "FAIL gc-traversal $g $o"; cat "$LOG/trav-$g$o.log" | tail -20; fail=1
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

echo
echo "=== ops.sh-equivalent (N=$N, ROUNDS=$ROUNDS, GCs interleaved) ==="
{
  echo "# load: $(cat /proc/loadavg)"
  for r in $(seq "$ROUNDS"); do
    for g in $GCS; do
      "$OUT/ops.$g" "$N" | sed "s/^[^ ]*/$g/"
    done
  done
} | tee "$LOG/ops-raw.txt"

python3 - <<'PY' | tee "$LOG/ops-table.md"
import collections, statistics, pathlib
d = collections.defaultdict(list)
for l in pathlib.Path("/tmp/c-baseline/logs/ops-raw.txt").read_text().splitlines():
    if l.startswith("#") or not l.strip():
        continue
    parts = l.split()
    if len(parts) != 3:
        continue
    g, op, v = parts
    d[(op, g)].append(float(v))
gcs = list(dict.fromkeys(g for _, g in d))
ops = list(dict.fromkeys(o for o, _ in d))
print("| op (ns/op) | " + " | ".join(gcs) + " |")
print("|---|" + "---:|" * len(gcs))
for o in ops:
    cells = []
    for g in gcs:
        xs = d[(o, g)]
        cells.append("%.2f" % statistics.median(xs) if xs else "—")
    print("| " + o + " | " + " | ".join(cells) + " |")
print()
print("raw samples:")
for (o, g), xs in d.items():
    print(f"  {g} {o}: n={len(xs)} min={min(xs):.2f} med={statistics.median(xs):.2f} max={max(xs):.2f} all={xs}")
PY

echo
echo "=== ops size sweep (N in 100000 1000000 4000000; 3 rounds; median) ==="
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

echo
echo "=== traversal bench sizes (perceus/incremental -O3, 5 interleaved) ==="
{
  for n in 4096 16384 32768; do
    echo "## traversal N=$n"
    for r in 1 2 3 4 5; do
      for g in perceus incremental; do
        echo -n "gc=$g n=$n r=$r "
        /usr/bin/time -f 'elapsed_s=%e peak_rss_kb=%M' "$OUT/trav-$g-O3" "$n" 2>&1 | tr '\n' ' '
        echo
      done
    done
  done
} | tee "$LOG/traversal-bench.txt"

echo
echo "=== ops peak RSS (one run per GC, N=$N) + KX_GC_STATS ==="
{
  for g in $GCS; do
    echo "## $g"
    /usr/bin/time -f 'elapsed_s=%e peak_rss_kb=%M' env KX_GC_STATS=1 "$OUT/ops.$g" "$N" 2>&1
  done
} | tee "$LOG/ops-rss-stats.txt"

echo
echo "=== sha256 of original C sources (immutable baseline) ==="
{
  git -C "$ROOT" rev-parse HEAD
  sha256sum "$ROOT/kxgc.h" "$ROOT/common/"*.inc "$ROOT/"*/gc.c "$ROOT/bench/ops/ops.c" \
    "$ROOT/tests/archive/unit/"*.c "$ROOT/tests/archive/incremental/one_pass.c"
} | tee "$LOG/source-hashes.txt"

echo
echo "C baseline complete. Logs in $LOG"
