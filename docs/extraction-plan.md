# Plan: extracting the GC into a separate project

**Status: planned, nothing has moved yet.** The GC code still lives in `compiler/gc` and everything in
[`../README.md`](../README.md) is current. This page describes the intended split so that new GC work
(code, tests, benchmarks) already respects the future boundary.

## What moves to the GC project

| Today (in `pyrlyn/kotlinx`) | In the GC project | Language |
|---|---|---|
| `compiler/gc/kxgc.h` | public API header (the only contract with the compiler) | C |
| `compiler/gc/common/object.inc`, `regions.inc`, `trial_deletion.inc` | shared internals: object header/colors, RC + tracing regions, trial-deletion cycle collector | C |
| `compiler/gc/{default,incremental,epoch,rc,boehm}/gc.c` + `caps` / `config.sh` | one directory per collector | C |
| `compiler/gc/tests/unit/*.c` | C unit tests (being ported to Zig, see below) | C -> Zig |
| `compiler/gc/tests/kt/*`, `tests/epoch/*`, `tests/incremental/*` | Kotlin-level GC tests (need `newkotlinc`, see "Tests") | Kotlin |
| `bench/gc/` (`compare.sh`, `micro.sh`, `micro/*.kt`) and `bench/gc/zig` (PR #155) | GC benchmarks and Zig regression benchmarks with baselines | sh / Kotlin / Zig |
| GC mutation tooling (source-level mutations of the C code, run against the Zig test suite; in progress) | mutation testing of the collectors | Python / Zig |
| `compiler/gc/docs/` | architecture and plans | Markdown |

What stays in KotlinX: the runtime (`compiler/runtime/runtime.c`), the code generator
(`NativeBackend.kt`, which inlines the retain/release fast paths and knows the object layout), the
`--gc` driver option, and the Kotlin golden/leak tests that are not GC-specific.

## API boundary

The boundary is `kxgc.h` and nothing else:

- functions called by generated code and the runtime: `rt_alloc` / `rt_free`, `rt_alloc_trace` /
  `rt_free_trace`, `rt_cc_possible_root`, `rt_cc_dead`, deferred RC (`rt_gc_log_inc`, `rt_gc_log_dec`,
  `rt_gc_write_barrier`, only for collectors with the `deferred` capability such as `epoch`),
  `rt_gc_mem_alloc` / `calloc` / `realloc` / `free`, `rt_gc_collect`, `rt_gc_name`, `rt_gc_stats`;
- the object layout shared with the code generator: header word (count in bits 0-31, color in bits
  32-33, buffered bit 34) and the `KxVTab` prefix `{rel, trav, relo, freemem, cyclic}`;
- each collector's `caps` file (`cycles`, `precise`, `asan`, `deferred`, ...), which tells the compiler
  and the tests what the collector supports.

Any change to the layout or to a function signature is a breaking API change and must be made in both
projects together (see "Versioning").

## Working with it after extraction

- **Build:** collectors stay single-file C translation units. `newkotlinc` keeps compiling
  `<gc dir>/<name>/gc.c` in the same `clang -O3 -flto` invocation as the runtime and the program, so the
  default collector is still inlined at no extra cost. No prebuilt library is required.
- **Link / locate:** KotlinX finds the GC sources through `NEWKOTLIN_GC_DIR` (already supported;
  default `<runtime dir>/../gc`). After the move the default will point at the pinned checkout of the
  GC project (git submodule or a fetched source tree; to be decided when the move happens).
  `NEWKOTLIN_BDWGC_DIR` keeps working for `--gc=boehm`.
- **Select:** unchanged: `--gc=<name>` / `--gc <name>` or `NEWKOTLIN_GC`.
- **Tests:** the GC project runs its Zig suite (`zig build test`, C collectors linked through
  `@cImport`) and the Zig benchmarks on its own. Kotlin-level GC tests need a `newkotlinc` binary, which
  the GC project will take from a pinned KotlinX build or a `NEWKOTLINC` path. KotlinX keeps running
  `compiler/gc/tests/run.sh`-equivalent smoke tests against the pinned GC version in `compiler/test.sh`.
- **Versioning / pinning:** KotlinX pins an exact GC commit or tag. The `kxgc.h` API gets a version
  macro; KotlinX checks it at compile time. Updating the GC = bump the pin in a KotlinX PR that runs the
  full compiler and GC test suites and the GC benchmarks.

## Rules until the move

- New GC tests are written in Zig (see [`../README.md`](../README.md#tests)).
- GC code must not include compiler or runtime headers other than `kxgc.h`.
- Keep GC benchmarks and their baselines under `bench/gc/` so they move as one directory.
