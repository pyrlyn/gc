# Native Zig port

Zig **0.14.1** (libc). Frozen C baseline: git SHA
`21f34a960f8b56d1dcdf1ab55b8e5e14e4e8ff31`.

## Layout

```
src/kxgc.zig                 KXGC_API_VERSION 1 types / ABI
src/host.zig                 runtime symbols (rt_nanos, rt_panic, rt_rel_draining, …)
src/common/{object,regions,trial_deletion}.zig
src/{rc,perceus,incremental,epoch}.zig
tests/native/suite.zig       gc_unit + api_test + traversal + one_pass
bench/native/ops.zig         port of bench/ops/ops.c
build.zig                    zig build test / zig build bench
artifacts/c-baseline/        immutable pre-port C measurements
artifacts/zig-bench/         Zig measurements on the same machine
```

Original C files stay in place as the immutable reference. They are not compiled
by `build.zig`. The Zig collectors export the same `kxgc.h` functions.

## Build / test / bench

```sh
# Zig 0.14.1 on PATH
zig build                          # Debug/ReleaseSafe test + ops binaries
zig build test                     # native suite, all collectors
zig build test -Dgc=perceus
zig build --release=fast           # optimized test + ops binaries (LTO on ops)
./zig-out/bin/gc-test-<gc>
./zig-out/bin/gc-ops-<gc> [N] [op]
```

## Ported

| Piece | Status |
|---|---|
| `kxgc.h` types / C ABI exports | yes |
| `common/object.inc` | yes |
| `common/regions.inc` (non-`RT_LEAKCHECK` path) | yes |
| `common/trial_deletion.inc` | yes |
| `rc/gc.c` | yes |
| `perceus/gc.c` | yes |
| `incremental/gc.c` | yes |
| `epoch/gc.c` log protocol, CRC trial deletion, Sigma/Delta, generations, drain | yes |
| `tests/archive/unit/gc_unit.c` | yes (native) |
| `tests/zig/src/unit/api_test.zig` | yes (native, no `@cImport`) |
| `tests/archive/unit/traversal.c` | yes (perceus / incremental) |
| `tests/archive/incremental/one_pass.c` | yes |
| `bench/ops/ops.c` | yes |

## Remaining / unportable (not silently dropped)

| Piece | Why it stays |
|---|---|
| `tests/kt/*.kt`, `tests/epoch/*.kt`, `tests/incremental/*.kt` | Need `newkotlinc` + KotlinX runtime. Not in this repo. |
| `bench/micro.sh`, `bench/compare.sh`, `bench/zig` | Need `newkotlinc` / `nkbench.sh`. Kotlin harnesses, not collectors. |
| `bench/third_party/boehm` | Third-party C (bdwgc). Benchmark-only. License stays with that tree. |
| `tests/zig/*` existing harness | Still links **C** collectors. Kept as the historical C-via-Zig suite. |
| `tests/zig/mutation` | Mutates C source. |
| epoch parallel MarkGray/Scan, incremental major, side-minor, early validation, slab `madvise` | Semantics of logs / CRC / Sigma-Delta / generations are implemented. Those C paths are pause/RSS optimizations; they are **not** claimed equivalent yet. |
| `RT_LEAKCHECK` / ASan region tags | KotlinX `--leak-check` / `--alloc malloc` builds. Need the compiler. |
| KotlinX `runtime.c` | Lives in pyrlyn/kotlinx. Host stub is Linux `CLOCK_MONOTONIC` only. |

## Verdict

**NOT READY** for a performance-sensitive pin. Native tests pass. Optimized ops
benches are meaningfully slower than the frozen C baseline in several
categories (see `artifacts/zig-bench` and the PR table). Do not update C
baselines.
