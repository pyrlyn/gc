# Native Zig port

Zig **0.17.1** (official latest 0.17 stable, 2026-11-02,
https://ziglang.org/download/). `master` is **0.18.0-dev** — do not use it.

Frozen C collector SHA: `21f34a960f8b56d1dcdf1ab55b8e5e14e4e8ff31`.

## Layout

```
src/kxgc.zig                 KXGC_API_VERSION 1 types / ABI
src/host.zig                 runtime symbols (rt_nanos, rt_panic, rt_rel_draining, …)
src/common/{object,regions,trial_deletion}.zig
src/{rc,perceus,incremental,epoch}.zig
tests/native/suite.zig       gc_unit + api_test + traversal + one_pass
bench/native/ops.zig         port of bench/ops/ops.c
build.zig                    zig build test / zig build bench
scripts/macos/               local Mac C + Zig 0.17.1 commands
artifacts/c-baseline/        frozen Linux VM C measurements (not Mac)
artifacts/zig-bench/         Linux VM Zig measurements (not Mac)
artifacts/macos-local/       local Mac destination + runner-reported C medians
```

Original C files stay as the immutable reference. They are not compiled by
`build.zig`. The Zig collectors export the same `kxgc.h` functions.

## Build / test / bench

```sh
# Official Zig 0.17.1 on PATH (not 0.17.0, not 0.18.0-dev)
zig version   # must print 0.17.1
zig build test
zig build --release=fast
./zig-out/bin/gc-test-<gc>
./zig-out/bin/gc-ops-<gc> [N] [op]
```

### Local Mac (paired C vs Zig on that machine)

```sh
./scripts/macos/install-zig-0.17.1.sh   # refuses anything other than 0.17.1
# mise 0.17.0 / 0.16.0 on the Mac are not 0.17.1
export PATH="$PWD/.zig-0.17.1:$PATH"
./scripts/macos/c-baseline.sh
./scripts/macos/zig-regression.sh
./scripts/macos/zig-bench.sh
python3 scripts/macos/test_compare.py
python3 scripts/macos/compare.py --pair mac-local --label "local Mac"
```

Zig 0.17.1 has no LLVM LTO on Mach-O. Official `zig build --release=fast` uses
ReleaseFast everywhere and full LTO only when the object format is ELF/COFF.

Paired Mac numbers for SHA `31bdbcf` live on the runner at
`~/Grok/gc-local-bench/` (not in this repo). `compare.py` now keys
`(N, collector, op)` so mixed-N C logs are not aggregated against Zig 4M.

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
| `epoch/gc.c` logs, CRC TD, Sigma/Delta, generations, drain | yes |
| epoch slab-release allocator (default on, `KX_GC_SLAB_RELEASE=0` restores bump/free-list) | yes (serial) |
| `tests/archive/unit/gc_unit.c` | yes (native) |
| `tests/zig/src/unit/api_test.zig` | yes (native) |
| `tests/archive/unit/traversal.c` | yes (perceus / incremental) |
| `tests/archive/incremental/one_pass.c` | yes |
| `bench/ops/ops.c` | yes |

## Remaining / unportable (not silently dropped)

| Piece | Why it stays |
|---|---|
| `tests/kt/*.kt`, `tests/epoch/*.kt`, `tests/incremental/*.kt` | Need `newkotlinc` + KotlinX runtime. Not in this repo. |
| `bench/micro.sh`, `bench/compare.sh`, `bench/zig` | Need `newkotlinc` / `nkbench.sh`. Kotlin harnesses, not collectors. |
| `bench/third_party/boehm` | Third-party C (bdwgc). Benchmark-only. |
| `tests/zig/*` existing harness | Still links **C** collectors. Historical C-via-Zig suite. |
| `tests/zig/mutation` | Mutates C source. |
| epoch parallel MarkGray/Scan, incremental major, side-minor, early validation | C pause/RSS paths. Not claimed equivalent. Serial collector thread = `KX_GC_THREADS=1`. |
| `RT_LEAKCHECK` / ASan region tags | Compiler-driven. |
| KotlinX `runtime.c` | Lives in pyrlyn/kotlinx. Host stub matches its clock on macOS. |

## Verdict

**NOT READY.** Native tests pass on Zig 0.17.1 (Debug and ReleaseFast, 4/4).
Mac SHA `19d8182` official scripts passed; epoch `field_store` closed to +1.4%.
Remaining Mac bottleneck is epoch `alloc_drop` (C 13.07 vs Zig 15.24 ns, +16.6%
at N=4M). This SHA thins `allocTrace`/`freeTrace`/`slab_*` so Darwin no-LTO
matches C’s inlined alloc/drop protocol. Full collector parity is still
incomplete. Linux VM timings are not Mac-to-Mac. Do not update C baselines.
