# GC per-operation micro-benchmarks

`ops.c` drives the GC interface (`compiler/gc/kxgc.h`) the way generated code does for a possibly cyclic
class, one operation shape at a time; `./ops.sh [gc ...]` builds it per GC (`-DDEFERRED` for GCs with the
`deferred` capability, i.e. epoch's log calls) and prints ns/op, median of 5 per run, median over
`ROUNDS` interleaved rounds (`N` operations per repetition, `OP=<name>` runs one shape only).

| op | what |
|---|---|
| `rc_pair` | retain + release of a live object (a local read from a field) |
| `field_store` | reference store into a live object's field: retain new, store (+ barrier), release old |
| `alloc_drop` | allocate and drop a young object |
| `lru_move` | move a random node of a 64K-node doubly linked list to the front (lru's `get` hit path) |

## Where lru's time went (2026-11-03)

Apple M3 Max, load 8-11 (other jobs running: treat ±10% as noise). `lru` (bench/cases/lru): epoch 337 ms,
boehm ~175, default ~90; epoch's GC pauses were only ~105 ms.

- Counting the log calls in lru (instrumented copy of epoch): 3M `get` calls make 22.9M `rt_gc_log_inc`,
  22.9M `rt_gc_log_dec`, 14.0M `rt_gc_write_barrier` (plus 8.8M with a null argument): ~20 log entries
  and ~35 log calls per `get`.
- Decomposition on lru (medians of 5-11 interleaved runs): log calls as no-ops (nothing reclaimed) 128 ms;
  logging with a collector that applies nothing 242 ms; full epoch 290 ms. So most of the gap is the
  mutator's logging, not the collector.
- The log entry points were real calls: `log_op` had a slow path (first-log setup) inline, so it was never
  inlined and every entry paid a call plus a 3-register-pair prologue / epilogue. `sample` on a 30M-op lru
  showed the hot instructions in `log_op` itself.
- Fix (this change): the first-log setup moved out of line (`log_first`), `log_op` and the three entry
  points are `always_inline`; LTO now inlines them into generated code (no `bl _rt_gc_log_*` left in lru).

Per operation after the fix (`ROUNDS=5 ./ops.sh`, load ~9.5; `epoch-before` is main, `epoch-nop` a local
copy with the log calls as no-ops, i.e. the floor for this code shape):

| op (ns/op) | epoch-before | epoch | epoch-nop | default | boehm |
|---|---:|---:|---:|---:|---:|
| rc_pair | 4.11 | 2.70 | 1.68 | 2.13 | 1.36 |
| field_store | 5.88 | 4.60 | 1.14 | 2.99 | 2.14 |
| alloc_drop | 10.72 | 10.40 | 4.09 | 4.66 | 56.24 |
| lru_move | 83.55 | 42.99 | 30.08 | 26.99 | 25.89 |

(`pause_ms` in the raw output is the GC's total pause over all shapes of one run.)

Kotlin benchmarks, main vs this change, `--gc=epoch`, 10 interleaved runs each, median ms / peak RSS MiB:

| bench | before ms | after ms | Δ | before RSS | after RSS |
|---|---:|---:|---:|---:|---:|
| lru | 388 | 250 | -36% | 45.1 | 54.4 |
| alloc_throughput | 81 | 80 | -1% | 2.2 | 2.2 |
| big_live_churn | 665 | 676 | +2% | 167.4 | 167.0 |
| cycles | 143 | 144 | +1% | 18.3 | 18.3 |
| cyclic_garbage | 141 | 144 | +2% | 3.8 | 3.7 |
| huge_live_churn | 1070 | 1080 | +1% | 693.4 | 688.4 |
| live_heap_churn | 449 | 445 | -1% | 33.0 | 34.2 |
| short_lived | 77 | 78 | +1% | 2.2 | 2.2 |
| trees | 120 | 121 | +1% | 10.2 | 10.2 |
| wide_graph_churn | 3688 | 3513 | -5% | 842.2 | 842.2 |

lru's RSS varies run to run (27-55 MiB on both sides). Everything except lru is within noise.

## What is left (lru still ~250 ms vs boehm ~175)

- **Log volume.** ~20 entries per `get`, most from locals read out of fields (`val p = e.prev`: increment
  ... decrement) and repeated stores into one object. Tried a runtime peephole over the last 8 log entries
  (cancel an increment/decrement pair, drop duplicate barriers): entries 60M -> 28M and collector apply
  243 -> 57 ms, but a correct cancellation must still mark the object a possible root (a pair can move
  its last outside reference into a cycle; `api_test.zig` "a logged garbage cycle is reclaimed" catches the
  naive version), so detection work stays, and the window scans cost more mutator time than they save:
  lru 260 -> 293-316 ms. Not included. The real fix is in code generation: no log calls for borrowed
  locals (needs a safety argument: a dead object is freed only at a later boundary).
- **Collector trial deletion on live data.** Every pointer swap in the list makes live entries purple roots;
  detection then traces live nodes (detect ~150-185 ms on the collector thread) and back-pressure stalls
  the mutator (~70-80 ms). Larger logs (`KX_GC_LOG_CAP`) do not help lru: it already runs at the maximum.
