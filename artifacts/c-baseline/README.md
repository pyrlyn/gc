# Frozen pre-port C baseline

Recorded **before any C implementation edit** from git SHA
`21f34a960f8b56d1dcdf1ab55b8e5e14e4e8ff31` on this machine.

- Toolchain: Ubuntu clang 18.1.3, `-O3 -flto` (ops), `-O1`/`-O3` (units)
- Host: Linux 6.12.94+, Intel Xeon, 4 cores, Ubuntu 24.04.5 LTS
- `kx_runtime_host.c` is **not** the KotlinX runtime. It only supplies
  `rt_nanos` / `rt_panic` / `rt_gc_note_pause` / `rt_rel_draining` so the
  original collectors and `bench/ops/ops.c` can run on Linux.
  KotlinX `runtime.c` uses `clock_gettime_nsec_np` (macOS).
- Kotlin `micro.sh` / `compare.sh` / `tests/kt` were **not** run: this repo
  has no `newkotlinc`. That is a blocker for those workloads, not a claimed
  baseline.

Reproduce:

```sh
# from a checkout of 21f34a9, with this host stub
clang -O3 -flto -I. bench/ops/ops.c artifacts/c-baseline/host/kx_runtime_host.c perceus/gc.c -o /tmp/ops.perceus -lpthread
```

Raw logs: `logs/`. Machine-readable: `c_baseline.json`.
