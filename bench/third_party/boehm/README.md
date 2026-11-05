# Boehm (bdwgc) collector — third-party, benchmark baseline only

The former `--gc=boehm` collector (RC + [bdwgc](https://github.com/bdwgc/bdwgc) 8.2.12 for cycles), moved here
from `compiler/gc/boehm`. The compiler, runtime, GC tests and `compiler/test.sh` do not reference or link it:
`newkotlinc` only looks for collectors in `compiler/gc/<name>/gc.c`. Only the GC benchmarks (`bench/gc`) use it
as a comparison baseline, through `bench/gc/gcdir.sh` (a `NEWKOTLIN_GC_DIR` with this directory added).
bdwgc: `mise install` here (`mise.toml`), or set `NEWKOTLIN_BDWGC_DIR`.
