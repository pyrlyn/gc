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
bench/native/cycles.zig      cycle-collector workload (perceus / incremental), native and wasm
scripts/wasm/                plain-JS WASI host: runs the wasm32-wasi binaries in Node/Bun/Deno/browser
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
| `incremental/gc.c` | yes, with its own step scheduler (see below) |
| `epoch/gc.c` logs, CRC TD, Sigma/Delta, generations, drain | yes |
| epoch slab-release allocator (default on, `KX_GC_SLAB_RELEASE=0` restores bump/free-list) | yes (serial) |
| `tests/archive/unit/gc_unit.c` | yes (native) |
| `tests/zig/src/unit/api_test.zig` | yes (native) |
| `tests/archive/unit/traversal.c` | yes (perceus / incremental) |
| `tests/archive/incremental/one_pass.c` | yes |
| `tests/incremental/slice_black.kt` scenario | yes (hand-built graph in `suite.zig`) |
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

## incremental scheduler

`src/incremental.zig` keeps C's trial deletion but schedules steps differently; the C file is
unchanged. Details are in the header comment of `src/incremental.zig`.

- **Slice size from a cost model.** Slices are sized from `t = fixed + per_root * n`, fitted
  from the slices already run, instead of C's fixed 64 roots. `fixed` is the live graph the roots
  share, which every slice re-traces; slices grow until that cost is amortized.
- **Stopping and one-pass rules.** A step stops before a slice predicted to cross the budget.
  When the shared graph alone is over the budget, a step runs one slice with as much root work as
  the graph costs, instead of one pass whose pause grows with the buffer.
- **Rescanning.** The live-black rescan of left-over roots runs only when the step blackened a
  buffered root (`TrialDeletion.blackened_buffered`). C rescans the whole backlog after every
  bounded step.
- **Buffer handling.** The buffer is consumed in place from `cc_head`, with no copying or
  reallocation per bounded step.
- **Pacing.** An unfinished step resumes after half as many new roots as it processed.
- **Threshold.** The threshold adapts once per cycle, when the buffer empties, not once per step.
- **`rt_gc_idle_step(budget_us)`** is not in `kxgc.h`. It runs one bounded step with the caller's
  budget (e.g. JS `requestIdleCallback`) and returns the roots still buffered.

Workload: `bench/native/cycles.zig` (`gc-cycles-<gc> [N] [scenario]`). Each iteration drops an
a↔b cycle. In `shared_<L>`, the cycle also points into a live ring of L objects, so trial
deletion re-traces the ring. `bench/native/cycles.sh` runs every scenario.

Medians of 5 runs, Apple Silicon, N=1M, ReleaseFast. *base* is the previous scheduler (a port of
C's) with the same host and clock fixes:

| target | scenario | ns/cycle base → new | max pause µs | peak RSS MB |
|---|---|---|---|---|
| native | garbage | 34 → 34 | 342 → 338 | 3.0 → 3.0 |
| native | shared_1k | 145 → 38 | 1381 → 395 | 45.7 → 3.0 |
| native | shared_20k | 804 → 72 | 3187 → 527 | 499 → 5.0 |
| native | shared_200k | 107 → 85 | 5493 → 2907 | 22.4 → 27.3 |
| wasm (Node) | garbage | 55 → 51 | 569 → 477 | 18.3 → 18.4 |
| wasm (Node) | shared_1k | 455 → 55 | 2070 → 500 | 72.3 → 18.6 |
| wasm (Node) | shared_20k | 1283 → 116 | 4545 → 2421 (p99 4405 → 557) | 179 → 31.4 |
| wasm (Node) | shared_200k | 190 → 148 | 9450 → 8753 | 46.2 → 44.0 |

`gc-ops` (rc_pair, field_store, alloc_drop, lru_move) is unchanged within noise on both targets.

Known limits:

- In `shared_200k`, re-tracing the ring alone costs about 3 ms natively and 9 ms in wasm. No
  slice fits the 500 µs budget, so pauses are bounded by about twice that cost. Native peak RSS
  is 22% higher than base because the backlog can reach the cap before a one-pass step.
- wasm `shared_20k` has a single max pause well above its p99.

## wasm32-wasi / JS

```sh
zig build --release=fast -Dtarget=wasm32-wasi --prefix zig-out-wasm   # rc, perceus, incremental
node scripts/wasm/run.mjs zig-out-wasm/bin/gc-test-incremental.wasm
node scripts/wasm/run.mjs zig-out-wasm/bin/gc-cycles-incremental.wasm 1000000 shared_1k
```

- **Supported collectors.** `epoch` is not built for wasm because it needs threads.
- **WASI host.** `scripts/wasm/wasi.mjs` is a dependency-free WASI preview1 host (args, environ,
  clocks, stdout/stderr, random). It runs in Node, Bun, Deno and browsers. `run.mjs` passes
  `KX_GC_*` variables through to the program.
- **Clock.** `rt_nanos` calls WASI `clock_time_get(MONOTONIC)` directly. In wasi-libc,
  `CLOCK_MONOTONIC` is a pointer, so `clock_gettime(.MONOTONIC)` through `std.c` read another
  clock with 1 ms resolution under JS hosts, and the incremental budget could not be measured.
- **Peak RSS.** On wasm, peak RSS is the size of linear memory.

## Verdict

**NOT READY.** Native tests pass on Zig 0.17.1 (Debug and ReleaseFast, 4/4).
Mac SHA `19d8182` official scripts passed; epoch `field_store` closed to +1.4%.
Remaining Mac bottleneck is epoch `alloc_drop` (C 13.07 vs Zig 15.24 ns, +16.6%
at N=4M). This SHA thins `allocTrace`/`freeTrace`/`slab_*` so Darwin no-LTO
matches C’s inlined alloc/drop protocol. Full collector parity is still
incomplete. Linux VM timings are not Mac-to-Mac. Do not update C baselines.
