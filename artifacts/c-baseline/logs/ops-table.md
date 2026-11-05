| op (ns/op) | perceus | incremental | epoch | rc |
|---|---:|---:|---:|---:|
| rc_pair | 1.67 | 1.65 | 9.37 | 1.66 |
| field_store | 3.50 | 3.46 | 7.60 | 3.45 |
| alloc_drop | 4.41 | 4.38 | 12.56 | 4.77 |
| lru_move | 31.59 | 31.11 | 77.08 | 24.97 |
| pause_ms | 1.10 | 1.00 | 467.10 | 0.00 |

raw samples:
  perceus rc_pair: n=5 min=1.64 med=1.67 max=1.73 all=[1.67, 1.73, 1.71, 1.65, 1.64]
  perceus field_store: n=5 min=3.44 med=3.50 max=3.55 all=[3.49, 3.55, 3.5, 3.5, 3.44]
  perceus alloc_drop: n=5 min=4.38 med=4.41 max=4.77 all=[4.38, 4.53, 4.38, 4.41, 4.77]
  perceus lru_move: n=5 min=31.00 med=31.59 max=33.04 all=[31.59, 33.04, 31.68, 31.2, 31.0]
  perceus pause_ms: n=5 min=1.10 med=1.10 max=1.10 all=[1.1, 1.1, 1.1, 1.1, 1.1]
  incremental rc_pair: n=5 min=1.65 med=1.65 max=1.71 all=[1.7, 1.71, 1.65, 1.65, 1.65]
  incremental field_store: n=5 min=3.43 med=3.46 max=3.48 all=[3.48, 3.46, 3.46, 3.43, 3.47]
  incremental alloc_drop: n=5 min=4.37 med=4.38 max=4.39 all=[4.37, 4.37, 4.38, 4.39, 4.38]
  incremental lru_move: n=5 min=31.09 med=31.11 max=31.29 all=[31.29, 31.09, 31.12, 31.11, 31.1]
  incremental pause_ms: n=5 min=1.00 med=1.00 max=1.10 all=[1.0, 1.0, 1.1, 1.0, 1.0]
  epoch rc_pair: n=5 min=8.66 med=9.37 max=9.45 all=[9.45, 9.37, 8.83, 8.66, 9.38]
  epoch field_store: n=5 min=7.34 med=7.60 max=7.78 all=[7.6, 7.76, 7.78, 7.47, 7.34]
  epoch alloc_drop: n=5 min=12.02 med=12.56 max=12.98 all=[12.43, 12.02, 12.75, 12.56, 12.98]
  epoch lru_move: n=5 min=74.38 med=77.08 max=77.66 all=[77.08, 74.38, 77.66, 77.5, 75.84]
  epoch pause_ms: n=5 min=442.90 med=467.10 max=477.90 all=[457.1, 442.9, 477.9, 467.1, 474.3]
  rc rc_pair: n=5 min=1.65 med=1.66 max=1.71 all=[1.71, 1.65, 1.66, 1.66, 1.7]
  rc field_store: n=5 min=3.44 med=3.45 max=3.57 all=[3.45, 3.44, 3.48, 3.45, 3.57]
  rc alloc_drop: n=5 min=4.69 med=4.77 max=4.97 all=[4.86, 4.69, 4.77, 4.72, 4.97]
  rc lru_move: n=5 min=24.42 med=24.97 max=26.47 all=[24.92, 24.42, 25.05, 24.97, 26.47]
  rc pause_ms: n=5 min=0.00 med=0.00 max=0.00 all=[0.0, 0.0, 0.0, 0.0, 0.0]
