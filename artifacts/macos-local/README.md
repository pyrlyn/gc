# Local Mac results (empty until a Mac runs the scripts)

This directory is the destination for **local Mac** C and Zig measurements
from `scripts/macos/`. It is not the frozen Linux VM baseline.

- Frozen Linux VM C data: `artifacts/c-baseline/` (do not overwrite)
- Linux VM Zig data: `artifacts/zig-bench/` (VM only; never label as local Mac)

After a Mac run:

```
artifacts/macos-local/c/logs/
artifacts/macos-local/zig/logs/
```
