# C vs Zig ops (same machine, N=4000000, median of 5 interleaved rounds)

C: clang 18.1.3 `-O3 -flto`. Zig: 0.14.1 `--release=fast` + LTO.

Positive Δ% means Zig is slower. Verdict: **NOT READY** if any meaningful category is slower.

| collector | op | C | Zig | Δ% | RSS C KiB | RSS Zig KiB |
|---|---|---:|---:|---:|---:|---:|
| perceus | rc_pair | 1.67 | 1.68 | +0.6% | 11644 | 11628 |
| perceus | field_store | 3.5 | 4.25 | +21.4% SLOWER | 11644 | 11628 |
| perceus | alloc_drop | 4.41 | 5.53 | +25.4% SLOWER | 11644 | 11628 |
| perceus | lru_move | 31.59 | 33.49 | +6.0% SLOWER | 11644 | 11628 |
| perceus | pause_ms | 1.1 | 1.3 | +18.2% SLOWER | 11644 | 11628 |
| incremental | rc_pair | 1.65 | 2.16 | +30.9% SLOWER | 11640 | 11636 |
| incremental | field_store | 3.46 | 4.48 | +29.5% SLOWER | 11640 | 11636 |
| incremental | alloc_drop | 4.38 | 6.96 | +58.9% SLOWER | 11640 | 11636 |
| incremental | lru_move | 31.11 | 46.09 | +48.2% SLOWER | 11640 | 11636 |
| incremental | pause_ms | 1.0 | 1.3 | +30.0% SLOWER | 11640 | 11636 |
| epoch | rc_pair | 9.37 | 8.02 | -14.4% | 11628 | 11632 |
| epoch | field_store | 7.6 | 8.11 | +6.7% SLOWER | 11628 | 11632 |
| epoch | alloc_drop | 12.56 | 42.27 | +236.5% SLOWER | 11628 | 11632 |
| epoch | lru_move | 77.08 | 85.53 | +11.0% SLOWER | 11628 | 11632 |
| epoch | pause_ms | 467.1 | 918.5 | +96.6% SLOWER | 11628 | 11632 |
| rc | rc_pair | 1.66 | 1.62 | -2.4% | 11628 | 11636 |
| rc | field_store | 3.45 | 4.03 | +16.8% SLOWER | 11628 | 11636 |
| rc | alloc_drop | 4.77 | 5.47 | +14.7% SLOWER | 11628 | 11636 |
| rc | lru_move | 24.97 | 33.56 | +34.4% SLOWER | 11628 | 11636 |
| rc | pause_ms | 0.0 | 0.0 | — | 11628 | 11636 |

## Size sweep (Zig median of 3, ns/op)

| N | op | perceus | incremental | epoch | rc |
|---:|---|---:|---:|---:|---:|
| 100000 | rc_pair | 1.65 | 2.13 | 9.58 | 1.62 |
| 100000 | field_store | 4.27 | 4.80 | 8.13 | 4.29 |
| 100000 | alloc_drop | 5.50 | 7.04 | 43.10 | 5.00 |
| 100000 | lru_move | 33.83 | 45.74 | 82.15 | 36.40 |
| 100000 | pause_ms | 1.30 | 1.30 | 27.40 | 0.00 |
| 1000000 | rc_pair | 1.70 | 2.17 | 7.95 | 1.65 |
| 1000000 | field_store | 4.26 | 4.52 | 8.16 | 4.33 |
| 1000000 | alloc_drop | 5.55 | 7.00 | 41.00 | 6.02 |
| 1000000 | lru_move | 34.61 | 47.15 | 88.21 | 34.25 |
| 1000000 | pause_ms | 1.30 | 1.30 | 225.70 | 0.00 |
| 4000000 | rc_pair | 1.73 | 2.23 | 7.96 | 1.66 |
| 4000000 | field_store | 4.39 | 4.87 | 8.50 | 4.22 |
| 4000000 | alloc_drop | 5.56 | 7.02 | 40.50 | 5.61 |
| 4000000 | lru_move | 33.81 | 47.83 | 91.31 | 34.06 |
| 4000000 | pause_ms | 1.40 | 1.30 | 998.80 | 0.00 |

ready=False
