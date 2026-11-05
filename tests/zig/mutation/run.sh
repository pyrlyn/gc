#!/bin/bash
# Source-level mutation testing of the GC C code against the Zig GC suite.
# Mutants are generated and applied by the shared mutate.py (the same engine the old-suite mutation job
# uses: operators eq-ne, lt-le, and-or, plus-minus, const-*, negate-if, del-stmt, drop-rc, ...). Every
# mutant is written into a private copy of compiler/ under $WORK, never into the checkout, and the Zig
# suite (gc-suite, prebuilt by `zig build`) runs in that copy for the collector(s) that use the file.
# Outcomes: killed (suite fails or does not build), survived, timeout.
#
# usage: mutation/run.sh FILE [MAX]     e.g. mutation/run.sh compiler/gc/epoch/gc.c 20
# env:   MUTATE_PY  path to mutate.py (default: $HOME/Grok/mutation-tests/kotlinx/mutation/mutate.py)
#        WORK       scratch dir (default: $HOME/Grok/kotlinx-gc-zig-tests/mutants); TIMEOUT (s, default 600)
#        SEED, JOBS (default 1: the suite times GC behavior, keep the machine quiet)
# Then: mutation/report.py $WORK  (caught / survived / timeout, survivors cross-referenced with coverage)
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"; root="$(cd "$here/../../../.." && pwd)"
file=$1; max=${2:-0}
MUTATE_PY=${MUTATE_PY:-$HOME/Grok/mutation-tests/kotlinx/mutation/mutate.py}
WORK=${WORK:-$HOME/Grok/kotlinx-gc-zig-tests/mutants}
[ -f "$MUTATE_PY" ] || { echo "mutate.py not found (set MUTATE_PY)"; exit 2; }
(cd "$here" && zig build) >/dev/null
# Collectors whose suite runs: the one the file belongs to, or every gc.c that includes a common/*.inc.
case "$file" in
  compiler/gc/common/*) gcs=$(for g in "$root"/compiler/gc/*/gc.c; do grep -q "$(basename "$file")" "$g" && basename "$(dirname "$g")"; done | tr '\n' ' ') ;;
  compiler/gc/*/gc.c) gcs=$(basename "$(dirname "$file")") ;;
  *) echo "not a GC source: $file"; exit 2 ;;
esac
work="$WORK/$(echo "$file" | tr / _)"; mkdir -p "$work"
nkc="$root/compiler/build/newkotlinc.kexe"; [ -x "$nkc" ] || (cd "$root" && compiler/build.sh >/dev/null)
# The copy holds compiler/gc and compiler/runtime (the suite's C inputs and Kotlin tests); the compiler
# binary and the prebuilt Zig objects are shared read-only.
setup="mkdir -p compiler && cp -R '$root/compiler/gc' '$root/compiler/runtime' compiler/ && mkdir -p compiler/build"
test="GCS='$gcs' NKC='$nkc' '$here/zig-out/bin/gc-suite' --obj '$here/zig-out/obj'"
echo "mutating $file; suite collectors: $gcs; work: $work"
exec python3 "$MUTATE_PY" run --root "$root" --file "$file" --setup "$setup" --test "$test" --work "$work" \
  --timeout "${TIMEOUT:-600}" --max "$max" --seed "${SEED:-1}" --jobs "${JOBS:-1}"
