#!/bin/sh
# Benchmarks only: prints a NEWKOTLIN_GC_DIR with every compiler/gc collector plus the third-party Boehm
# collector (bench/gc/third_party/boehm), so `--gc=boehm` works as a comparison baseline in bench/gc. The compiler,
# runtime and tests never see this directory; outside benchmarks `--gc=boehm` does not exist.
root=$(cd "$(dirname "$0")/../.." && pwd -P)
d="$root/compiler/build/bench-gc-dir"
rm -rf "$d"; mkdir -p "$d"
for e in "$root"/compiler/gc/*; do ln -s "$e" "$d/$(basename "$e")"; done
ln -s "$root/bench/gc/third_party/boehm" "$d/boehm"
echo "$d"
