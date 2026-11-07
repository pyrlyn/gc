# Local Mac C baseline (reported by the Mac runner)

These numbers were measured on the **actual Mac**, not on the cloud VM.
The VM cannot read `~/Grok/gc-local-bench/c-logs/` on that machine. The
values below were supplied by the local runner so the Zig port can target
them. They are **not** a C-vs-Zig comparison (Zig has not been run on that
Mac yet).

Do not treat `artifacts/c-baseline/` (Linux VM) as these Mac numbers.

## Host (as reported)

- Apple M3 Max, arm64, macOS 27.0.1
- Apple clang 21, `-O3 -flto`
- Unchanged C at `21f34a960f8b56d1dcdf1ab55b8e5e14e4e8ff31`
- Darwin host stub (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`)
- Five interleaved rounds, N=4_000_000, median ns/op
- Raw + 100K/1M sweeps: Mac `~/Grok/gc-local-bench/c-logs/c_baseline_mac.json` and `ops-raw.txt`

## N=4M median ns/op (perceus / incremental / epoch / rc)

| op | perceus | incremental | epoch | rc |
|---|---:|---:|---:|---:|
| rc_pair | 1.34 | 1.34 | 3.65 | 1.00 |
| field_store | 2.40 | 2.48 | 5.10 | 2.16 |
| alloc_drop | 3.60 | 3.75 | 15.86 | 3.40 |
| lru_move | 24.96 | 25.63 | 55.55 | 26.83 |
| pause_ms | 0.9 | 0.9 | 520.9 | 0.0 |

Peak RSS (extra N=4M run): 5.42 / 5.42 / 9.14 / 4.77 MiB.

C archive units (as reported): **11 PASS, 2 SKIP, 0 FAIL**.

## Zig toolchain on that Mac (as reported)

- Official latest stable is **0.17.1** (2026-11-02, https://ziglang.org/download/)
- mise currently has **0.17.0** and **0.16.0**; **0.17.1 is not installed yet**
- 0.17.0 is official 0.17 but is **not** the requested patch; use 0.17.1
- `master` is 0.18.0-dev — do not use

Install 0.17.1 with `./scripts/macos/install-zig-0.17.1.sh` (refuses any other version).
