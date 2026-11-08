# Epoch allocation size classes — 2026-11-08

Baseline: `bad8e04fd0ad314590ce90842c06bc09ad3c7e77` (current main at task start).
Candidate: `codex/epoch20`, native Zig epoch only; C sources and the public ABI are unchanged.
Host: Apple M3 Max, macOS; Zig 0.17.1, ReleaseFast, normal build.zig Mach-O settings (no LLVM LTO).

## Change and result

Traced objects of 257–4096 bytes now share 64 KiB slabs instead of each reserving a
64 KiB large-object block. Classes through 256 bytes keep their 8-byte granularity;
medium classes advance by 64 bytes. The tables have 92 classes and each slab fits
at least 16 cells. Both the releasing allocator and `KX_GC_SLAB_RELEASE=0` use the
same size-to-class conversion when allocating and freeing.

The 20% speed / 20% memory target is exceeded for allocation-heavy medium objects.
For example, at 512 bytes all four operation medians improve by more than 20%, and
peak RSS falls by 93%. **This is not a universal 20% improvement for epoch**: the
original 40-byte workload remains approximately unchanged. Workloads outside the
new size range, and workloads dominated by LRU mutation, have no guaranteed gain.

## Paired size sweep

1,000,000 operations, 4096 live objects, the same harness for both revisions.
Requested payload bytes are touched. Each process reports the median of five timed
repetitions per operation. After one warm-up per binary, five independent process
runs per revision alternate baseline/candidate order. The table gives medians
across those runs. RSS is the process peak reported by getrusage, including live
objects, collector metadata and runtime overhead. A positive reduction is better.

| Object bytes | alloc_drop ns/op, before → after | Time reduction | Peak RSS MiB, before → after | RSS reduction |
|---:|---:|---:|---:|---:|
| 40 | 9.15 → 9.14 | +0.1% | 2.88 → 2.86 | +0.5% |
| 256 | 16.28 → 14.98 | +8.0% | 4.52 → 4.50 | +0.3% |
| 264 | 345.62 → 19.43 | +94.4% | 114.33 → 5.06 | +95.6% |
| 512 | 349.60 → 43.80 | +87.5% | 98.44 → 6.48 | +93.4% |
| 1024 | 403.25 → 73.97 | +81.7% | 98.42 → 9.48 | +90.4% |
| 4096 | 598.15 → 249.21 | +58.3% | 98.42 → 26.53 | +73.0% |
| 4104 | 608.40 → 601.71 | +1.1% | 98.42 → 114.42 | -16.3% |

Other operation medians (ns/op; lower is better):

| Object bytes | rc_pair before → after | field_store before → after | lru_move before → after |
|---:|---:|---:|---:|
| 40 | 2.84 → 2.78 | 4.28 → 4.37 | 37.67 → 37.92 |
| 256 | 3.30 → 3.40 | 5.22 → 5.05 | 42.21 → 57.96 |
| 264 | 15.40 → 3.87 | 22.30 → 14.00 | 65.25 → 47.01 |
| 512 | 15.65 → 3.64 | 21.96 → 10.63 | 63.05 → 42.02 |
| 1024 | 15.34 → 3.57 | 22.04 → 5.83 | 64.29 → 54.14 |
| 4096 | 14.85 → 12.05 | 21.48 → 17.32 | 62.83 → 38.91 |
| 4104 | 15.29 → 15.23 | 21.66 → 21.61 | 66.77 → 63.30 |

All samples and summary calculations: [results.json](results.json).
No trials were dropped. The combined 256-byte LRU workload is noisy (baseline
33.54–68.08 ns, candidate 40.45–79.22 ns); its median worsened, so these results do
not establish a regression-free speedup across every operation. The 4104-byte
large-object path is unchanged; its measured RSS increased by approximately
16 MiB, consistent with an extra batch of in-flight large allocations (the
cause was not separately established). These observations are retained in the
table, not excluded from the comparison.

A follow-up isolated `lru_move` run at 256 bytes, N=4,000,000, 4096 live objects
(five alternating process runs per revision) gave medians 66.02 → 50.52 ns.
It did not reproduce the combined-workload slowdown; scheduling and collector
state still cause substantial scatter. Raw samples: [lru-256.json](lru-256.json).

## Original workload

The original N=4,000,000 / 65536 live / 40-byte workload was also run five times
per revision in alternating order. Medians:

| Metric | Before | After |
|---|---:|---:|
| rc_pair ns/op | 2.50 | 2.54 |
| field_store ns/op | 3.88 | 3.97 |
| alloc_drop ns/op | 10.24 | 10.29 |
| lru_move ns/op | 49.55 | 51.43 |
| Peak RSS KiB | 6688 | 6656 |

Raw samples: [default-ops.json](default-ops.json). The requested 20%/20% target is
**not met** on this original workload.

## Correctness

- `zig build test`: all four collectors passed in Debug.
- `zig build test --release=fast`: all four collectors passed in ReleaseFast.
- Epoch also passed with `KX_GC_SLAB_RELEASE=0`.
- Epoch also passed with `KX_GC_SLAB_KEEP=0 KX_GC_MAX_QUEUED=1 KX_GC_LOG_CAP=7`.
- New deferred tests exercise 15 allocation sizes, including 256/257,
  512/513, 4096/4097 and 65536/65537. They verify reachable rings survive,
  every payload byte remains intact, and unreachable rings are reclaimed
  exactly once, across three reuse rounds.
- Zig formatting, `git diff --check`, and benchmark-runner Python compilation passed.

This validates the native harness, not KotlinX compiler/runtime integration.

## Reproduce

From the repository root with Zig 0.17.1 on PATH (output directory must not exist):

```sh
python3 scripts/macos/epoch-size-bench.py \
  --baseline bad8e04fd0ad314590ce90842c06bc09ad3c7e77 \
  --zig zig --n 1000000 --output artifacts/epoch-sizing-rerun
```

The runner snapshots both versions, uses the current identical harness for each,
clears `KX_GC_*` overrides, builds each size, and saves every run and a candidate
source patch. Frozen C baselines are not used or updated.

A single medium-object run:

```sh
zig build --release=fast -Dgc=epoch -Dbench-object-size=512 -Dbench-live=4096
./zig-out/bin/gc-ops-epoch 1000000
```

Omit both benchmark options for the original 40-byte / 65536-live workload.
