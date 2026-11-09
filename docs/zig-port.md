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
bench/native/phases.zig      size-class phases: memory one size class frees, reused by the next
bench/native/churn.zig       random free-and-replace of live objects (LRU-cache-like)
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
| `common/regions.inc` (non-`RT_LEAKCHECK` path) | yes, with another pool (see below) |
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

## Pool

`src/common/regions.zig` keeps C's region API (`rt_alloc_trace` / `rt_free_trace`, 8-byte size
classes up to 256 bytes, larger objects from malloc) but not C's pool. C bump-allocates every size
class from one shared 64 KiB slab and reuses a freed block only for its own class, so memory freed
by one class never serves another: a program that frees many 40-byte objects and then allocates
64-byte ones keeps both peaks.

Compaction here does not move objects. `kxgc.h` visitors receive child values, not field
addresses, and generated code holds raw pointers, so an object can never be relocated. Instead:

- **Single-class pages.** Each 16 KiB page holds blocks of one class after a 32-byte header, and
  is aligned to its size, so a block finds its page by masking its address.
- **Fast paths unchanged.** Allocation is still C's free-list pop or bump, and a free is C's push
  onto the class's free list. Neither touches a page header.
- **Lazy reclaim.** When a class needs a page and the stock is empty, a walk of the free lists
  starts. It goes through one class at a time and sorts its blocks by page, at most 4096 blocks
  per page taken, so no single allocation sorts a whole heap. A page whose blocks are all free
  leaves its list for a stock that every class, and both pools, take pages from; the rest go back
  grouped by page. A class whose list is unchanged since its last walk is skipped. While its list
  is being walked, a class allocates from the blocks the walk has not reached yet.
  The next walk waits until the pages handed out since the last one began exceed, by 64 KiB, the
  bytes that walk left on the lists (a page the stock gives back to the class that emptied it
  counts as left), so walking costs at most one block per 8 bytes allocated.

Memory is never returned to the system, as in C.

A first version counted live blocks on every free, as the epoch collector's slabs do. Freeing a
block outside the current page then touched that page's header, and the next allocation switched
to it. Freeing and replacing objects in random order, as an LRU cache does, was 3-8 times slower
than C's pool natively and 1.8 times slower in wasm. `bench/native/churn.zig` measures that case.

The walk's cost shows when one class frees many small blocks in random order and another then
allocates: 1M 16-byte blocks freed shuffled, then 100K 200-byte objects, five times, takes about
1.2 times C's time natively (in allocation order, under 2 times), and one page take can sort 4096
scattered blocks, a few hundred microseconds. In exchange the 200-byte objects reuse the 16-byte
pages: peak RSS 108 MB instead of 124 MB. With one 16-byte survivor in every 64 blocks (pages
that never empty) followed by six size classes in turn, peak RSS is 55 MB instead of 102 MB.

Pages come from the system in chunks. Natively, a chunk is a 1 MiB `page_allocator` mapping that
becomes resident as its pages are used. On wasm, a chunk is a `memory.grow` of an eighth of the
pages carved so far, from 64 KiB up to 1 MiB. Through malloc, C's 64 KiB slab was a 128 KiB block
(the allocator's 16-byte header), and once JS has read `memory.buffer`, every grow costs about
4-90 µs under V8 and about 1 ms under Bun.

On wasm the RC region (`rt_alloc`) also has a pool, as with C's `RT_POOL`, instead of libc malloc,
which rounds every block to a power of two (a 40-byte object took a 64-byte slot). Natively it
stays libc malloc.

The free stays as small as C's for another reason too: V8 inlines a wasm function into its caller
only within a budget of about three times the caller's size. With the counting free inlined into
release functions, V8 inlined `objRel` at 4 of 8 call sites in `gc-ops lru_move` instead of 6, and
perceus and incremental were 40-65% slower under Node, Deno and Bun.

The compiler must also be able to tell the pools apart from objects. A pointer to a pool or to
one of its classes stored in memory (a table of pools, the class a walk is in), a block made from
an integer address, or a block returned by an out-of-line call may, as far as LLVM knows, point
into a pool. Every object store on the inlined fast paths then forces the free-list head to be
reloaded, and an allocation after a free was no longer folded away (`churn` at 1M live objects ran
1.4 times slower natively). The walk therefore keeps classes as indexes, the bump range is held as
pointers, and `refill` returns nothing: the caller pops or bumps again.

Workload: `bench/native/phases.zig` (`gc-phases-<gc> [live] [rounds] [keep_every]`) allocates
`live` objects of one size (40 to 256 bytes), frees them, and moves on to the next size.
`keep_every=K` keeps every K-th object alive, pinning its page. `bench/native/churn.zig`
(`gc-churn-<gc> [live] [iters]`) keeps `live` 40-byte objects and replaces a random one `iters`
times, allocating the replacement before freeing the old object (in the other order LLVM folds
the free and the allocation into nothing, and the bench measured no allocator at all).

### Results

HEAD (`2a1217d`) → this tree, medians of interleaved runs (5 native, 3 per JS engine), Apple
Silicon under heavy unrelated load (load average 70-100), so differences under about 15% are
noise. wasm peak RSS is the size of linear memory. Time in ns per object, op or cycle. Churn ran
5M iterations, in the order described above for both sides.

| bench | native | Node | Bun | Deno |
|---|---|---|---|---|
| phases rc, time | 17.5 → 21.4 | 40.8 → 24.6 | 24.4 → 30.6 | 46.8 → 26.2 |
| phases rc, peak MB | 77.7 → 34.2 | 166 → 34.3 | 166 → 34.3 | 166 → 34.3 |
| churn perceus, live 64K | 2.69 → 3.01 | 9.44 → 11.2 | 4.12 → 5.12 | 9.53 → 9.99 |
| churn perceus, live 1M | 13.0 → 15.3 | 52.0 → 60.2 | 13.0 → 13.7 | 51.1 → 57.0 |
| churn, live 1M, peak MB | 50.0 → 50.0 | 104 → 49.7 | 104 → 49.7 | 104 → 49.7 |
| cycles incremental garbage | 49.3 → 52.4 | 87.6 → 93.4 | 116 → 92.4 | 98.7 → 88.7 |
| cycles incremental, peak MB | 3.0 → 3.0 | 18.3 → 2.4 | 18.3 → 2.4 | 18.3 → 2.4 |
| ops perceus lru_move | 36.9 → 38.7 | 41.5 → 41.9 | 40.9 → 26.9 | 29.4 → 28.3 |
| ops rc rc_pair | 1.34 → 1.51 | 4.00 → 3.21 | 2.71 → 2.92 | 3.26 → 3.00 |
| ops rc, peak MB | 4.9 → 4.9 | 21.8 → 4.4 | 21.8 → 4.4 | 21.8 → 4.4 |

Memory: wasm instances are 4-7 times smaller on small heaps (most of it the shadow stack, 16 MiB →
1 MiB), and half the size when the heap is large or moves between size classes. Time: phases is
1.7-1.9 times faster under Node and Deno, whose `memory.grow` HEAD hit for every 64 KiB slab, and
10-25% slower natively and under Bun, the cost of sorting each freed class's blocks by page.
Random churn is 5-15% slower everywhere. In HEAD's churn loop LLVM keeps the free-list head in a
register (the loop's only call is malloc, which cannot touch the pool); here the loop also calls
`refill`, which writes it. The rest of `gc-ops` and the perceus and shared_1k cycles are unchanged
within noise. epoch does not use this pool; its numbers moved in both directions between runs.

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
- **Stack.** The shadow stack is 1 MiB (`-Dwasm-stack-size`), not Zig's default 16 MiB. It sits
  at the bottom of linear memory, so all of it counts toward every instance's memory. The
  collectors use explicit work stacks, and the tests and benches use under 32 KiB. An overflow
  traps instead of corrupting data, because the stack comes first.
- **Debug info.** Optimized wasm builds are stripped (`-Dstrip=false` keeps the names). DWARF was
  about 94% of the module, and engines keep the module bytes.
- **Large objects.** Objects over 256 bytes, and `rt_gc_mem_*` buffers, still come from libc
  malloc (`std.heap.BrkAllocator`). It rounds each block, plus its 16-byte header, up to a power of
  two (a 300-byte object takes 512 bytes), and grows memory 64 KiB at a time.
- **Host calls.** `wasi.mjs` keeps its views of `memory.buffer` and makes new ones only after a
  `memory.grow` detached the old buffer, instead of on every call. The monotonic clock comes from
  `process.hrtime.bigint()` where it exists. `random_get` fills buffers over 64 KiB in parts
  (the Web Crypto limit). `random_get` and `fd_write` read pointers as unsigned and return `EFAULT`
  for a buffer outside memory, because `subarray` would clamp it silently.
- **Root buffers.** Perceus keeps the possible-root buffer between collections, unless it is more
  than twice what the next collection needs (after a drain, or once the threshold drops). C moves
  the roots buffered during a collection to a fresh buffer, which then grows again from its
  initial capacity.
  `PtrStack` blocks are a power of two less the allocator's header, so they do not round up to the
  next size.

## Verdict

**NOT READY.** Native tests pass on Zig 0.17.1 (Debug and ReleaseFast, 4/4).
Mac SHA `19d8182` official scripts passed; epoch `field_store` closed to +1.4%.
Remaining Mac bottleneck is epoch `alloc_drop` (C 13.07 vs Zig 15.24 ns, +16.6%
at N=4M). This SHA thins `allocTrace`/`freeTrace`/`slab_*` so Darwin no-LTO
matches C’s inlined alloc/drop protocol. Full collector parity is still
incomplete. Linux VM timings are not Mac-to-Mac. Do not update C baselines.
