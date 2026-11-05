#!/bin/sh
# Prints extra clang flags for --gc=boehm: include + link flags for bdwgc.
# Order: $NEWKOTLIN_BDWGC_DIR, the repo's mise conda:bdw-gc (mise.toml), pkg-config bdw-gc.
here=$(cd "$(dirname "$0")" && pwd)
d=${NEWKOTLIN_BDWGC_DIR:-}
if [ -z "$d" ] && command -v mise >/dev/null 2>&1; then d=$(cd "$here" && mise where conda:bdw-gc 2>/dev/null); fi
if [ -n "$d" ] && [ -f "$d/include/gc.h" ]; then
  echo "-I'$d/include' -L'$d/lib' -lgc -Wl,-rpath,'$d/lib'"; exit 0
fi
if pkg-config --exists bdw-gc 2>/dev/null; then echo "$(pkg-config --cflags --libs bdw-gc)"; exit 0; fi
echo "error: bdwgc not found: run 'mise install' in the repo or set NEWKOTLIN_BDWGC_DIR" >&2; exit 1
