# Next step: epoch-based background cycle reclamation + TLABs

Status: section 1 implemented as `--gc=epoch` (see `architecture.md` section 7); TLABs (section 2) not started. Follows `--gc=incremental` (PR "incremental cycle collector"), whose limit is that one
trial-deletion slice is atomic and re-traces any large live graph reachable from its roots
(`live_heap_churn`, `bigheap`: max pause stays 9-13 ms).

## 1. Epoch-based reclamation (new implementation `compiler/gc/epoch/`, `--gc=epoch`)

Goal: replace the stop-the-world cycle pass with a pass that runs on a background thread, so the
mutator pauses only for short epoch boundaries (target: max pause < 1 ms on `bench/gc/micro`).

Design sketch (Bacon et al., "Concurrent Cycle Collection in Reference Counted Systems", 2001, adapted):
- **Epochs.** The mutator logs RC operations on traced objects into a per-epoch buffer instead of applying
  decrements that could start a cycle check. At an epoch boundary (allocation count or time) the mutator
  hands the buffer to the collector thread and starts a new one; the boundary is the only pause.
- **Write barrier on reference stores** (codegen, traced fields only): a store `o.f = v` into a possibly
  cyclic object logs `o` (and the overwritten target) in the current epoch's mod-buffer and sets a "dirty in
  epoch" header bit (bit 35 is free; codegen today touches only bits 0-34). Stores into acyclic objects and
  stack objects get no barrier, so Perceus fast paths are unchanged for them.
- **Collector thread:** applies the epoch's increments, then decrements (Levanoni-Petrank order), collects
  candidate roots, runs the synchronous trial deletion on its own snapshot, then the two safety tests from
  the paper (Sigma test: a cycle's external count is zero; Delta test: none of its members was modified in
  the epochs since it was found) before freeing. A cycle that fails a test is re-examined next epoch.
- **What must change outside compiler/gc:** the codegen emits the barrier call (`rt_gc_write_barrier(obj,
  old)`, a new kxgc.h hook, no-op inline for `default`), and RC on traced objects becomes deferred
  (counts in the header are only touched by the collector thread). Acyclic objects keep immediate RC.
- **Freeing** happens on the collector thread: the tracing region allocator must be thread-safe
  (mimalloc is; the pool needs a per-thread free list or a return queue).

Acceptance: `compiler/test.sh` + `compiler/gc/tests/run.sh` (incl. new tests: mutation during collection,
cycles relinked across epochs, TSan build), upstream counts unchanged (PASS 2006 / MISCOMPILE 38 /
CRASH 2) with `NEWKOTLIN_GC=epoch`, `bench/gc/compare.sh default epoch`, `bench/gc/micro.sh default epoch`;
max pause well below `incremental`, total time within noise of `default` on nkbench.

Risks: deferred RC for traced objects changes memory timing (peak RSS up); barrier cost on store-heavy
code (`lru`, `refpass`); needs pthreads in the runtime (no new dependency).

## 2. Follow-up note: TLABs (thread-local allocation buffers)

`cycles` and `trees` spend most of their time in per-object malloc/free (mimalloc). A TLAB gives each
thread a bump-pointer chunk per size class, so allocation is a pointer bump plus a limit check inlined in
generated code, and frees go to a thread-local free list (or back to the owning chunk). The tracing region
already uses size-class slabs (`common/regions.inc`); a TLAB version would make those slabs per-thread and
expose an inline fast path through kxgc.h (`rt_alloc` / `rt_alloc_trace` as header-inline functions with
an out-of-line refill). Needed anyway once the epoch collector frees on another thread. Measure with
`bench/gc/micro.sh` (`alloc_throughput`, `short_lived`) and nkbench `alloc`, `trees`, `cycles`.
