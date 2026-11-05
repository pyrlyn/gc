# GC regression benchmarks (Zig harness)

A `zig build test` gate for the epoch collector. It compiles the existing KotlinX GC benchmark programs
with `bin/newkotlinc --gc=epoch` (and `--gc=boehm` for reference), runs each one, and **fails loudly**
when a metric crosses its threshold. Every failure line names the benchmark, the metric and the numbers:

```
!!! GC REGRESSION [wide_graph_churn] time: epoch 4712.000 ms > limit 4607.280 ms (baseline 4266.000, 10.5%; allowed 5% (epoch strongly beats Boehm) + 3% noise)
!!! GC TARGET NOT MET [cyclic_garbage] peak RSS: epoch 4.10 MiB > Boehm target 3.40 MiB ...
```

Zig 0.17 std + libc only (no new dependencies). The programs are the ones the shell scripts use:
`bench/gc/micro/*.kt` and `bench/cases/{alloc,bigheap,cycles,lru}/kotlin/Main.kt`.

## Running

```sh
mise install                     # repo root (pinned opt) and bench/gc/third_party/boehm (bdwgc; --gc=boehm via ../gcdir.sh)
cd bench/gc/zig
zig build test                   # all categories, median of 5 runs
zig build test -Donly=cyclic_garbage,wide_graph_churn -Druns=9
zig build test -Dnoise=0         # quiet machine: no noise margin
zig build test -Dboehm=true      # also measure Boehm for every benchmark (prints it side by side)
zig build update-baselines -Dcommit=$(git rev-parse --short HEAD)
```

| option | default | meaning |
|---|---|---|
| `-Druns=N` | 5 | measured runs per benchmark after one warm-up; every metric is the median |
| `-Dnoise=F` | 0.03 | measurement-noise margin added to every limit |
| `-Dallow=F` | 0.05 | regression allowed where epoch strongly beats Boehm |
| `-Dstrong-ratio=F` | 1.5 | `boehm / epoch` in the baseline at or above which epoch "strongly beats" Boehm |
| `-Dpause-slack=MS` | 0.1 | absolute slack on max-pause limits (sub-millisecond pauses jitter) |
| `-Dbetter=F` | 0.05 | improvement that prints a "refresh baselines" note |
| `-Dload-warn=L` | 4 | warn when the 1-minute load average exceeds `L` |
| `-Donly=a,b` | all | benchmark names to run |
| `-Droot=PATH` | auto | repository root (default: nearest parent of the cwd containing `bin/newkotlinc`) |

Tests (one per category): allocation (`alloc_throughput`, `short_lived`, suite `alloc`), big live heaps
(`live_heap_churn`, `big_live_churn`, `huge_live_churn`), `bigheap`, cyclic garbage (`cyclic_garbage`,
suite `cycles`), `lru`, wide graph (`wide_graph_churn`). A full run takes a few minutes.

## What is measured

- **time**: the program's own kernel time (`nanos=`, as `micro.sh`/`nkbench.sh` report); wall time is
  measured with a monotonic `Timer` (std's `std.time.Timer` no longer exists in Zig 0.17, so the harness
  has a tiny `clock_gettime` equivalent) and used only if a program prints no `nanos=`.
- **peak RSS**: `ru_maxrss` from `wait4` for the child (same source as `/usr/bin/time -l`).
- **max pause**: `pause_max` from the collector's `gc-stats:` line (`KX_GC_STATS=1`, every measured run).

Single runs can be far off on a loaded machine (one run here saw 42.9 MiB where the median is 22.6), so
use at least 5 runs; the load average is printed with each benchmark.

## Thresholds

For every metric with a baseline (`baselines.zon`):

- **epoch strongly beats Boehm** (`boehm / epoch >= 1.5` in the baseline, e.g. allocation time, big live
  heaps time/RSS/pauses, `bigheap`, `wide_graph_churn`, `huge_live_churn` max pause):
  `limit = baseline × (1 + 5% + noise)`.
- **everywhere else** (e.g. `lru` time, where Boehm wins; `cycles`; `cyclic_garbage` RSS and pause):
  no regression, `limit = baseline × (1 + noise)`.
- max-pause limits get `+0.1 ms` absolute slack.
- **cyclic_garbage peak RSS ≤ Boehm**: epoch must be at or below `cyclic_rss_target_mib` (3.4 MiB,
  Boehm's measured peak) and, because Boehm is measured side by side for this benchmark, at or below the
  Boehm peak of the same run (+noise).

**This target is not met on main yet.** After #147 epoch peaks at 4.1 MiB on `cyclic_garbage` (22.6 MiB
before #147), so the cyclic garbage test is *expected to fail* until the epoch cyclic-garbage work
lands; the failure message says so. It is deliberately not relaxed.

## Baselines

`baselines.zon` holds the latest known-good epoch numbers plus Boehm reference numbers. Initial values:

- micro benchmarks, epoch: PR #147 (`bench/results/gc-epoch-short-logs` on `perf/epoch-cycle-queue-bound`,
  "new" rows), the worse of its two 5-run medians per metric; Boehm: the same files, run 1;
- suite `alloc`/`bigheap`/`cycles`/`lru`: PR #148 (`bench/results/gc/nk-{epoch,boehm}.txt`), main before
  #147 (#147 did not report suite numbers).

Until #147 is on main, the post-#147 limits also fail on main (e.g. `cyclic_garbage` 22.6 MiB).

### Refreshing baselines (standing rule)

Thresholds track the latest known-good baseline: **when a landed change measures notably better than the
baselines** (cyclic garbage RSS well below 3.4 MiB, or any metric more than ~5% better), refresh them.
The test prints a `+++ ... refresh baselines` line in that case. To refresh:

1. check out the merged main on a quiet machine (load average well below 4);
2. `zig build update-baselines -Druns=9 -Dcommit=$(git rev-parse --short HEAD)`: it measures epoch and
   Boehm for every benchmark and rewrites `baselines.zon` (provenance: time, commit, runs, load);
3. review `git diff baselines.zon`: keep only genuine improvements (a noisy slower number must not loosen
   a limit; edit it back), then run `zig build test` once more and commit.

`cyclic_rss_target_mib` only ever tightens: it becomes the measured Boehm peak if that is lower.

## First run (2026-11-03 13:45 EET, main 30065af without #147, load 10–11, median of 5)

3 of 6 tests pass (allocation, bigheap, wide graph), 3 fail:

- cyclic garbage: epoch 22.6 MiB vs Boehm 3.41 MiB, max pause 1.75 ms vs baseline 0.126 (main does not
  have #147 yet; the 3.4 MiB target is expected to fail even after #147), `cycles` time +3.9%;
- big live heaps: `live_heap_churn` RSS 36.0 vs 33.7 MiB, `big_live_churn` time +18% (under load);
- LRU: 464 ms vs 403 ms baseline (+15%, no allowance since Boehm wins on `lru`).

`wide_graph_churn` (−16.5% time, −19% max pause) and `huge_live_churn` max pause (28.6 vs 57.0 ms) beat
the post-#147 baselines because main still runs the pre-#147 collector there.
