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
| `incremental/gc.c` | its interface and tests; the collector is another algorithm (see below) |
| `epoch/gc.c` logs, CRC TD, Sigma/Delta, generations, drain | yes |
| epoch slab-release allocator (default on, `KX_GC_SLAB_RELEASE=0` restores bump/free-list) | yes (serial) |
| `tests/archive/unit/gc_unit.c` | yes (native) |
| `tests/zig/src/unit/api_test.zig` | yes (native) |
| `tests/archive/unit/traversal.c` | yes (perceus / incremental) |
| `tests/archive/incremental/one_pass.c` | yes |
| `tests/incremental/slice_black.kt` scenario | yes (hand-built graph in `suite.zig`, stepped one object at a time) |
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

## incremental: interleaved trial deletion

`src/incremental.zig` keeps the interface and the tests of `incremental/gc.c`, not its algorithm;
the C file is unchanged. C runs MarkRoots / ScanRoots / CollectRoots over a slice of the root
buffer and subtracts the internal references from the counts themselves, so a slice has to trace
everything its roots reach, and restore it, before the program may run again: one root in front
of a million live objects was a pause of 170-340 ms, whatever the budget. The port:

- **Counts are never modified.** A cycle takes the roots buffered so far (`take`), counts in
  header bits of its own (bits 42-63, saturating) the references each object it reaches gets
  from the others (`mark`), and finds what is referenced from outside, and what that reaches
  (`scan`). The program runs between any two objects of that work and sees its own counts.
- **One atomic check.** What is left are candidates. `collect` takes them in batches of up to 256
  seeds and the candidates they reach, and checks each batch in one piece: every member has
  exactly as many references as the members hold to it. Nothing in `kxgc.h` tells the collector
  that the program moved a reference, so this check cannot be spread over steps, and it is the
  only thing soundness rests on: `mark` and `scan` only choose the candidates. A member that
  fails stays, and so does all it reaches. What passes is garbage the program cannot reach any
  more: it is released and freed in steps, like the rest of the cycle (it used to be freed in
  the same piece as the check, which made that piece twice as long).
- **Generations.** An object a cycle found live is old (header bit 40). A *minor* cycle, over
  the roots buffered since the last one, does not go into old objects, so it costs what the
  young objects behind its roots cost and not the live heap. Roots that are old, and the roots a
  minor cycle let go of after it had stopped at an old object (they may be garbage through it),
  stay buffered in a set of their own for a *major* cycle, which goes everywhere and works out
  again what is old. A major cycle is due when a quarter as many roots are deferred as the last
  one traversed objects (at least 10000; up to four times as many while majors free less than a
  quarter of what they traverse), or when the pool has grown by half since the last one (1 MiB
  at least). The second rule is what bounds garbage that goes through old objects: a deferred
  root stays buffered, so later decrements of it never reach the collector, and only the heap's
  growth tells. The pool calls the collector before it takes a page it has no stock for
  (`regions.grow_hook`).
- **Dead deferred roots.** A buffered object whose count reaches zero is left to the collector
  (`kxgc.h`). In the deferred set it would wait for a major cycle, so the set is gone through
  when the pool has grown by 32 bytes per deferred root (256 KiB at least): one header read per
  32 bytes allocated at most.
- **Held objects.** An object the cycle has reached is held: `rt_free_trace` keeps its memory
  until the cycle lets go of it, so the collector's sets never name freed memory. `BUF` stays
  what `kxgc.h` says, "in the root buffer": a held object the program decrements is buffered
  again, for the next cycle.
- **Bitmaps.** The root buffer and the two sets of a cycle are bitmaps, one bit per 8 bytes of
  the 16 KiB pages they cover (1.6% of the objects' memory at most), not 8 bytes per object.
- **Pacing.** A step runs for `KX_GC_BUDGET_US` (500 µs) once `threshold` roots are buffered,
  then every 64 new roots while the cycle is unfinished. The program gets at least as long as the
  step took; less as the buffer fills, and nothing from one threshold on, so garbage cannot be
  buffered faster than it is collected. The clock is read once per 256 objects.
- **Threshold.** It doubles after a cycle that reclaimed less than a quarter of what it traced
  (as C) and halves after one that reclaimed at least half. C goes back to the minimum after any
  productive cycle, which here made the threshold oscillate (10k, 20k, 40k, 10k).
- **`rt_gc_idle_step(budget_us)`** is not in `kxgc.h`. It runs one step with the caller's budget
  (e.g. JS `requestIdleCallback`) and returns the roots still buffered, deferred ones included:
  idle time is when a major cycle costs the program nothing. A cycle only advances when roots
  arrive, the program frees a held object or the pool grows; an idle program finishes it this
  way.

Tests (`tests/native/suite.zig`): the C suite's cases, the traversal counts, and a stress test
that runs a random mutator against the collector stepped 1, 3, 17 and 1000 objects at a time. It
checks that exactly the reachable objects are left, with exact counts, that none is freed twice
or while reachable, and that no freed memory stays held after the last cycle. 17 single
mutations of the collector's source (a skipped check, a missing propagation, memory kept after a
cycle) each fail the suite. `generations` checks the rules above one by one on a hand-built
graph: young garbage that refers to an old object is freed by a minor cycle, old garbage and
garbage through an old object by a major one, started by the roots or by the pool's growth alone,
which also frees a deferred root that died. The stress test runs minor cycles, major cycles and
sweeps in turn.

Workload: `bench/native/cycles.zig` (`gc-cycles-<gc> [N] [scenario]`). Each iteration drops an
a↔b cycle. In `shared_<L>`, the cycle also points into a live ring of L objects.
`bench/native/cycles.sh` runs every scenario. Medians, Apple Silicon under unrelated load, N=1M,
ReleaseFast, previous collector → this one:

| target | scenario | ns/cycle | max pause µs | roots buffered, max | peak RSS KB |
|---|---|---|---|---|---|
| native | garbage | 34.7 → 45.7 | 320 → 458 | 9999 → 9999 | 2992 → 2816 |
| native | shared_1k | 38.3 → 51.7 | 386 → 482 | 9999 → 9999 | 3024 → 2848 |
| native | shared_20k | 77.7 → 116 | 519 → 504 | 39999 → 16775 | 6736 → 3872 |
| native | shared_200k | 84.4 → 96.7 | 3126 → 508 | 312659 → 239359 | 24304-47712 → 24592 |
| wasm (Node) | garbage | 49.3 → 83.9 | 482 → 517 | 9999 → 18703 | 2496 → 2624 |
| wasm (Node) | shared_1k | 55.5 → 91.1 | 489 → 512 | 9999 → 18639 | 2368 → 2688 |
| wasm (Node) | shared_20k | 116 → 143 | 2353 → 511 | 39999 → 28111 | 5504 → 3392 |
| wasm (Node) | shared_200k | 145 → 154 | 9296 → 571 | 79999 → 241279 | 16320 → 19520 |

`gc-ops-incremental`, 4M operations. With 65536 live objects the collector `rc`, which collects
nothing, peaks at 4976 KB, and at 51232 KB with `-Dbench-live=1048576`: that is the memory of the
live objects, which no collector can go under.

| | rc_pair / field_store / alloc_drop / lru_move, ns | max pause | pauses, total | peak RSS KB |
|---|---|---|---|---|
| native, 65536 live | 1.15 / 1.99 / 3.37 / 23.1 → 1.15 / 2.00 / 3.38 / 23.3 | 554 → 501 µs | | 5584 → 5104 |
| native, 1M live | 28.2 / 340 / 3.4 / 2217 → 58.2 / 315 / 3.4 / 1201 | 169 ms → 0.57 ms | 24.7 → 14.1 s | 63488 → 58704 |
| wasm (Node), 65536 live | 1.53 / 2.38 / 3.32 / 16.1 → 1.51 / 2.31 / 3.54 / 27.0 | 1106 → 502 µs | | 5888 → 4800 |

### Generations and stepwise freeing: before → after

Same machine and method (medians of 3, under unrelated load). `shared_200k` no longer buffers
garbage while the live ring is traversed again and again: 190 full traversals per million cycles
became a handful of major ones.

| target | scenario | ns/cycle | max pause µs | roots buffered, max | peak RSS KB |
|---|---|---|---|---|---|
| native | garbage | 46.9 → 47.1 | 450 → 458 | 9999 → 9999 | 2832 → 2816 |
| native | shared_1k | 52.4 → 50.8 | 501 → 492 | 9999 → 9999 | 2864 → 2864 |
| native | shared_20k | 111 → 52.6 | 504 → 501 | 16839 → 14927 | 3904 → 3808 |
| native | shared_200k | 95.2 → 65.7 | 510 → 501 | 239615 → 19999 | 24656 → 12864 |
| wasm (Node) | garbage | 86.1 → 91.4 | 512 → 503 | 18767 → 18063 | 2624 → 2624 |
| wasm (Node) | shared_1k | 97.1 → 94.8 | 542 → 645 | 18767 → 17039 | 2688 → 2688 |
| wasm (Node) | shared_20k | 142 → 98.7 | 553 → 506 | 28175 → 17871 | 3392 → 3392 |
| wasm (Node) | shared_200k | 156 → 133 | 683 → 525 | 241471 → 23335 | 19520 → 11264 |

The 200000 live objects of `shared_200k` are 8 MB and an idle process 2 MB: 12.9 MB is what is
left above them. "Roots buffered" counts the roots no cycle has decided yet, not the deferred
roots of old objects (a bit each).

`gc-ops-incremental`, 4M operations per op:

| | rc_pair / field_store / alloc_drop / lru_move, ns | max pause | pauses, total | peak RSS KB |
|---|---|---|---|---|
| native, 65536 live | 1.13 / 1.93 / 3.30 / 23.6 → 1.16 / 2.03 / 3.35 / 23.1 | 501 → 501 µs | 2.0 → 1.8 ms | 5120 → 5136 |
| native, 1M live | 57.5 / 183 / 3.39 / 1044 → 1.15 / 5.4 / 3.5 / 72 | 534 → 501 µs | 22.6 s → 31 ms | 58656 → 52528 |
| wasm (Node), 65536 live | 1.50 / 2.33 / 3.56 / 26.5 → 1.56 / 2.32 / 3.52 / 27.3 | 509 → 503 µs | 5.2 → 6.8 ms | 4800 → 4800 |

With a million live objects the program now runs as with `rc` (1.00 / 4.75 / 3.37 / 69.8 ns,
51232 KB): the list is traversed once, is old from then on, and nothing in it becomes garbage.

One garbage ring at a time, collected in idle steps of 500 µs (`gc-cycles-incremental 4000000
ring_<L>`), longest step:

| | ring of 10k | 100k | 1M |
|---|---|---|---|
| native | 0.18 → 0.19 ms | 1.18 → 0.64 ms | 12.0 → 5.6 ms |
| wasm (Node) | 0.96 → 0.58 ms | 4.2 → 1.9 ms | 25.7 → 11.9 ms |

Known limits:

- **One garbage structure is checked in one piece**, about 5 ns per object natively and 11 in
  wasm (it was 11 and 25 with the freeing in the same piece): a step is the budget plus that, so
  a garbage ring of 100k objects that dies at once is a step of 0.6-0.7 ms natively and one of a
  million 5.6 ms. Bounding it needs a write barrier, which `kxgc.h` gives only to `epoch`.
- **Old garbage waits for a major cycle**: until a quarter as many roots are deferred as the
  last major cycle traversed objects, or the pool has grown by half (1 MiB at least). The pool
  is the traced objects (and the acyclic ones in wasm): memory that old garbage holds outside
  it, natively the acyclic objects and the storage of collections, is not counted.
- **Internal reference counts saturate at 22 bits** (24 before): an object with more than four
  million references from the objects of one cycle passes for live.
- **A garbage cycle costs more than with `perceus`**: 35 → 47 ns for a bare pair, 49 → 91 in
  wasm. `gc-churn-incremental` 1.8 → 2.0-2.4 ns per operation: `rt_free_trace` reads
  the header of the block it frees.
- **wasm memory** is 5-15% higher than with the previous collector in `garbage` and `shared_1k`,
  where twice as many roots are buffered at the peak.
- **wasm `lru_move` under V8**: 16 → 27 ns with the default tiering, although the collector runs
  14 steps in the whole measurement. With `--no-liftoff` (31.8 against 31.4) and with
  `--liftoff-only` (46.2 against 46.7) the two builds are equal, and the hot path of the bench's
  release function is the same code in both. That function grew by the held check of
  `rt_free_trace`, which points at V8's inlining heuristics. Bun: 13.9 → 16.1 ns.

## epoch: pauses, returned objects, slabs

What differs from `epoch/gc.c` on the mutator side, and what the port had lost.

- **Target pause.** `KX_GC_TARGET_PAUSE_US` defaults to 1000 here (C: 3000), and
  `KX_GC_FREE_BUDGET_US` to a quarter of it, at least 100 µs.
- **Freeing budget.** The port had dropped the budget of C's `process_returns`: one boundary freed
  everything the collector had returned. It is back: a boundary frees returned objects, a chunk
  of 254 at a time, until a quarter of the target pause has passed since it began (half, before:
  with the wait below a boundary came to 0.6-1.0 ms); allocations free the rest, 2 to 16 per
  call. A boundary that spent its time waiting still frees for 100 µs.
- **Back-pressure wait.** C waits until the queue is no longer than `KX_GC_MAX_QUEUED`, however
  long the collector takes. Here the wait ends after 2/5 of the target pause; the mutator goes on
  with a longer queue and meets the same wait at its next boundary, which throttles it to one log
  per wait. Past 524288 queued entries (64 full logs, 4 MiB: what the adaptive queue may hold
  anyway) the wait is unbounded again, so the queue cannot grow without limit. A wait that timed
  out counts as one over the target for the adaptive queue depth.
- **The collector serves the queue in the middle of its work.** A cascade of deaths or a cycle
  detection used to run to its end before the next log was applied: a million objects dying
  together kept the queue unserved for 10-20 ms, and the mutator waited at every boundary
  meanwhile. Both loops now look at the queue every 2048 steps (`poll`), hand over what they have
  released and apply one queued log; its decrements join the cascade, and an object a detection
  has marked is pinned (`MARKED_BIT`) so that a log applied meanwhile cannot free it under the
  trace. A detection polls less often the more roots wait for the next one (up to 16 times), so a
  program cannot make roots faster than detections retire them.
- **Logs** hold at most 8192 entries (64 KiB) instead of 32768 (256 KiB): a full log stays in
  the cache and a boundary hands over a quarter of the work.
- **Deferred decrements** of a detection are a bitmap (1 KiB per 64 KiB page) instead of a stack
  of pointers, and the stack of marked objects keeps at most 8192 entries between detections.
  After 64 logs applied without a detection the root threshold halves, and the log size with it:
  only a detection lowered it before, so a program without garbage cycles kept the largest logs.
- **Mutator state** read at every allocation and logged operation is one struct on its own
  cache lines. As separate globals it lay between counters the collector thread writes for every
  object: `alloc_drop` cost 10 or 13 ns depending on where the linker put them.
- **Returned objects** travel as a list of 2 KiB chunks, spliced under the lock in O(1) and freed
  once their objects are. As three stacks (C), publishing copied the batch under the lock and each
  stack kept the capacity of the largest batch ever (8 MiB apiece after a million deaths).
  An object leaves the list before it is freed: freeing it can fill the log and run a boundary
  that frees returned objects itself. The port advanced its cursor after the free, which freed
  that object twice (latent while every boundary emptied the list).
- **Slabs.** A slab emptied between two boundaries is reused by the next refill instead of
  waiting for the boundary's flush, and a flush gives at most 64 slabs back to the system.
  `gc-phases-epoch` took a new slab for each size class meanwhile: 309 MB, now 28 MB.
- **MarkGray** records every object it grays (C `tw->marked`), not only the roots, so that all
  are settled after the detection. Without it a cycle behind an edge the mutator removed between
  MarkGray and Scan stayed gray with its CRC and was never examined again (`deferredLostEdge` in
  `suite.zig`).
- `rt_gc_root_hint(null)` logs nothing (C logs a null entry, which the collector dereferences);
  `KX_GC_LOG_CAP` <= 0 is ignored, as in C.

Not changed, and different from C: `c_traversed` counts objects MarkGray popped, C counts edges
it followed; the adaptive thresholds were tuned with the port's count.

`bench/native/drop.zig` (`gc-drop-epoch [live] [rounds] [churn]`) drops a chain of `live` objects
at once and keeps allocating. Apple M3 Max under unrelated load. The first change (budget,
returned objects, slabs), minimum of interleaved runs, before → after:

| bench | time, ns | max pause | peak MB |
|---|---|---|---|
| drop, 1M objects | 11.5 → 12.1 | 11.5 ms → 0.61 ms | 59.3 → 50.0 |
| drop, 4M objects | 14.3 → 14.6 | 51 ms → 0.63 ms | 192 → 193 |
| phases epoch | 11.5 → 4.5 | | 309 → 28.1 |
| ops epoch alloc_drop | 9.49 → 9.36 | 72 µs → 77 µs | 6.7 → 6.6 |
| ops epoch rc_pair / field_store / lru_move | 2.34 → 2.35 / 3.29 → 3.24 / 21.5 → 22.8 | | |

The second (queue served mid-work, smaller logs, bitmap, quarter budget), medians, that state →
now:

| bench | time, ns | pause max / p99.9 / p99, µs | peak RSS KB |
|---|---|---|---|
| drop, 1M objects | 12.4 → 10.1 | 625 / 623 / 22 → 77 / 35 / 18 | 50016 → 41584 |
| drop, 4M objects | 15.0 → 11.1 | 992 / 623 / 557 → 565 / 35 / 25 | 193216 → 159328 |
| ops epoch, 65536 live | 2.35 / 3.63 / 9.50 / 23.4 → 2.14 / 3.76 / 9.54 / 24.8 | 83 / - / 11.8 → 90 / - / 9.2 | 6624 → 6448 |
| ops epoch, 1M live | equal within noise | 251 / - / 41 → 159 / - / 9.2 | 62592 → 53744 |
| phases epoch | 5.50 → 5.55 | | 28096 → 28112 |

A boundary is bounded by the wait (2/5 of the target) plus the freeing budget, not by one target:
about 0.6 ms at most in these runs, apart from the times the system deschedules the thread (one
`ops` run had a boundary of 0.84 ms, and one run in ten of the 4M drop had 1.3-1.6 ms before the
second change).

`perceus` cannot be bounded this way: it traces a live cyclic structure in the mutator (about
3 ms in `gc-cycles shared_200k`, 170-200 ms with a million live objects in
`gc-ops -Dbench-live=1048576`). `incremental` could not either and now can, see above; what is
left there is the check of one garbage structure.

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
  per page taken, so no single allocation sorts a whole heap. A page goes to a stock that every
  class, and both pools, take pages from as soon as its last block is sorted; the other pages go
  back to the class, grouped by page, when its list is done. A class whose list is unchanged since
  its last walk is skipped. While its list is being walked, a class allocates from the blocks the
  walk has not reached yet, then takes the sorted blocks of its partly free pages back.
  Emptied pages first waited for the end of their class's list: a class with 100000 free blocks
  took 25 new pages from the system before its own came back, at every walk, and `gc-phases-rc`
  grew with the number of rounds until every class held its peak (35 MB after 24 rounds, 80 MB
  after 240; now 28 MB after either, natively and on wasm, and 10-20% less time).
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
