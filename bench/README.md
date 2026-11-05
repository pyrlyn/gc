# GC benchmarks

Reproducible comparisons of the `--gc` implementations ([compiler/gc](../../compiler/gc/README.md)).
Run `mise install` in the repo first (bdwgc for `--gc=boehm`). Results go to `bench/results/gc/`.

- `./compare.sh [gc ...]` (default `default boehm`): the whole KotlinX suite (`bench/nkbench.sh`: warm-up +
  5 runs, mean of the middle 3) once per GC; prints a table, best value per row in bold.
- `./micro.sh [gc ...]`: GC-only microbenchmarks in `micro/` (allocation throughput, many short-lived
  objects, cyclic garbage, pauses with a large live cyclic heap): time, peak RSS (`/usr/bin/time -l`) and
  the GC's own statistics (`KX_GC_STATS=1`: collections, total and max pause), one table per metric.
- `./table.py label=file ...`: the table builder used by both (also for before/after runs of `nkbench.sh`).

### Run time

Where the ~1 h of a full `micro.sh default incremental epoch boehm` + `compare.sh` (same four) goes
(2026-11-03 run): `micro.sh` ~50 min, `compare.sh` ~5 min. Every micro (case, GC) pair runs 8 times
(warm-up, 5 timed, peak RSS, `KX_GC_STATS`), so `wide_graph_churn` alone is (100 s default + 194 s
incremental) x 8 ≈ 39 min, and `huge_live_churn` default/incremental (~18 s) x 8 x 2 ≈ 5 min. Compiling is
~0.6 s per binary; `compare.sh` used to rebuild all 17 cases per GC in every round (204 serial builds ≈ 2 min).

- Binaries are built once, in parallel (`BUILD_JOBS`, default 4), before any timed run, through the
  content-addressed cache `bench/nkbuild.sh` (`compiler/build/nkcache/`; key = compiler binary, runtime and
  GC sources, source file, flags; `NKBUILD_NOCACHE=1` rebuilds). Code and data are identical to a fresh
  build. No timed run overlaps a build; runs stay sequential and interleaved, iterations unchanged.
- Opt-in only, for quick iterations (a skipped pair has no row, shown as "—", and no `record.py` entry):
  `MICRO_SKIP="default:wide_graph_churn incremental:wide_graph_churn"` or `MICRO_MAX_S=60` (skip a pair
  whose warm-up exceeds 60 s). Either cuts the full four-GC run from ~1 h to ~15 min.
- Not done: running GCs in parallel. epoch uses background threads, so this would need a control run
  proving the medians stay within noise.

Close other heavy processes; results within ±3-5% are noise on a loaded machine.

## Shared-edge traversal regression

`compiler/gc/tests/archive/unit/traversal.c` checks live reference-count restoration, exact cycle reclamation,
and bounded traversal scratch space for a ring with 64 references per node to its successor. It also
checks a queued sibling restored by ScanBlack. The Zig suite (`compiler/gc/tests/zig`, port `src/unit/traversal.zig`) runs it for `default` and
`incremental` at `-O1`, `-O3`, and under ASan. From the repository root, benchmark a larger ring with:

```sh
clang -O3 -Icompiler/gc compiler/gc/tests/archive/unit/traversal.c compiler/runtime/runtime.c -o /tmp/gc-traversal
/usr/bin/time -l /tmp/gc-traversal 32768
# Add -DTEST_INCREMENTAL to select the incremental collector.
```

The explicit size enables benchmark mode (all correctness assertions remain, except the scratch-space
limit that the old collector fails). On Apple M3 Max, Apple clang 21.0.0, compared with `09daa04`,
medians of nine interleaved runs on 2026-10-31 were:

| GC | traversal scratch, before → after | peak RSS, MiB | total GC pause, ms | maximum GC pause, ms |
|---|---:|---:|---:|---:|
| default | 16 MiB → 2 KiB | 40.8 → 23.0 | 39.93 → 15.99 | 20.37 → 8.46 |
| incremental | 16 MiB → 2 KiB | 40.5 → 22.9 | 40.37 → 17.11 | 21.50 → 8.60 |

This deliberately stresses shared edges; it is not a general workload speedup or a hard pause bound.
Seven interleaved runs of the existing `cycles`, `lru`, and `trees` Kotlin benchmarks retained their
checksums; median kernel times changed from 49.09/116.79/122.86 ms to 48.45/113.50/122.10 ms, within
the usual 3–5% noise. Other compiler tests were running during these measurements.

## Result files

Every script also writes one file per benchmark, appending a run each time:
`bench/results/nk/<case>.json` (`nkbench.sh`), `bench/results/gc-nk/<case>.json` (`compare.sh`),
`bench/results/gc-micro/<bench>.json` (`micro.sh`). A run records date, commit (+ dirty flag), git ref,
machine (model, CPU, OS, load), toolchain (clang, opt), GC, flags and metrics (mean ms + raw timings;
for micro also peak RSS, total/max pause, collections). Writer: `bench/record.py`. The PR #3 results are
imported there (runs `gc-before`, `gc-after`, `gc-default`, `gc-boehm`, `micro-*`).

## Epoch experiment: main vs gc-improvement-experiment

`./main-vs-branch.sh <main-tree> <branch-tree> <out-dir>` builds each tree, runs `paced-run.sh` (GC tests,
micro benchmarks incl. p50/p99/max pause and peak RSS) and `compare.sh epoch default` (full nkbench suite).
The main tree needs `pause-percentiles.patch` applied (statistics only). Results:
`bench/results/gc-main-vs-branch/` (`main-*`, `branch-*` before madvise, `branch-madvise-*` micro after it,
`upstream-branch-<gc>.txt` upstream suite counts). Measured with machine load around 20: treat ±10% as noise.
