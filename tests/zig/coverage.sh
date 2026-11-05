#!/bin/sh
# `zig build coverage`: runs the whole Zig GC suite with clang source-based coverage
# (-fprofile-instr-generate -fcoverage-mapping on the collectors, the runtime and every test program), then
# merges the profiles with the llvm-profdata matching the C compiler and writes, under coverage/ (gitignored):
#   summary.txt       llvm-cov report (line / branch / function / region coverage per file)
#   html/index.html   llvm-cov show HTML
#   uncovered.txt     file:line of every never-executed line (used by mutation/report.py)
# Usage (via build.zig): coverage.sh <gc-suite binary> <unit object dir>
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../../../.." && pwd)"
suite=$1; obj=$2; cov="$here/coverage"
rm -rf "$cov"; mkdir -p "$cov"
# Apple clang is what run.sh and newkotlinc use on macOS; its profile format matches xcrun's tools.
if [ -x /usr/bin/clang ] && xcrun -f llvm-profdata >/dev/null 2>&1; then
  export NK_CC=/usr/bin/clang; PROFDATA="xcrun llvm-profdata"; LLVMCOV="xcrun llvm-cov"
else PROFDATA=llvm-profdata; LLVMCOV=llvm-cov; fi
(cd "$root" && "$suite" --obj "$obj" --coverage "$cov") >"$cov/suite.out" 2>&1
status=$?
cat "$cov/suite.out"
$PROFDATA merge -sparse "$cov"/raw/*.profraw -o "$cov/gc.profdata" || exit 1
objs=""; first=""
for b in $(cat "$cov/binaries.txt"); do if [ -z "$first" ]; then first=$b; else objs="$objs -object $b"; fi; done
srcs="$root/compiler/gc/perceus/gc.c $root/compiler/gc/epoch/gc.c $root/compiler/gc/incremental/gc.c $root/compiler/gc/rc/gc.c $root/compiler/gc/common/object.inc $root/compiler/gc/common/regions.inc $root/compiler/gc/common/trial_deletion.inc"
$LLVMCOV report "$first" $objs -instr-profile="$cov/gc.profdata" -show-branch-summary $srcs 2>/dev/null | sed "s|$root/||" >"$cov/summary.txt"
$LLVMCOV show "$first" $objs -instr-profile="$cov/gc.profdata" -format=html -show-branches=count -output-dir="$cov/html" $srcs 2>/dev/null
$LLVMCOV export "$first" $objs -instr-profile="$cov/gc.profdata" -format=lcov $srcs 2>/dev/null \
  | awk -v root="$root/" '/^SF:/{f=substr($0,4); sub(root,"",f)} /^DA:/{split(substr($0,4),a,","); if (a[2]==0) print f ":" a[1]}' \
  | sort -t: -k1,1 -k2,2n -u >"$cov/uncovered.txt"
echo; cat "$cov/summary.txt"
echo "coverage: $cov/summary.txt, $cov/html/index.html, $cov/uncovered.txt ($(wc -l <"$cov/uncovered.txt" | tr -d ' ') uncovered lines)"
exit $status
