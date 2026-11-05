# Proposal: per-epoch nursery with bump allocation (not prototyped)

Measurements on `gc-epoch-smooth` (bench/results/gc-epoch-smooth/): peak RSS of the epoch GC is the live
heap plus collector stacks that all fill during a major (huge_live_churn: slabs ~386 MiB, deferred list
128 MiB, im-seen 128 MiB, worker stacks 130 MiB). Releasing empty stacks after a major cut the peak only
963 -> 934 MiB, because the peak is the major itself. On nkbench, epoch and default are within noise except
cycles/lru, so the remaining throughput cost is per-object: every allocation and death goes through size-class
free lists, and every retain/release of a traced object is a log entry.

Idea: allocate traced objects of the current epoch into a per-epoch bump region (nursery). Retain/release
of an object whose epoch is the current one updates its count directly (no log entry); only objects that
survive the epoch boundary (count > 0 or reachable from an older object, found by the write barrier that
already logs modified objects) are evacuated or promoted in place; the rest of the region is reset in one
step and its pages reused. Why it should help: most objects in nkbench cases die young (alloc, closures,
strings, trees), so they would cost one bump and no free-list traffic or log entries; free lists, the
deferred list and im-seen would only see promoted objects, which also shrinks the major's stacks.
Risk: Kotlin/Native-style interior pointers from C stacks need pinning (a promoted-in-place flag instead of
moving), and finalizer-like `rel` calls of dying nursery objects must still run (acyclic fields); that is the
part that makes this a rewrite rather than a flag. Measurable goal: nkbench epoch geomean <= 0.9 of main
2c9e4a9 and huge_live_churn peak RSS <= 800 MiB; if a prototype cannot reach that, the per-object cost is
not the bottleneck and this direction should be dropped.
