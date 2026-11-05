# macOS native C vs Zig 0.17.1 (local Mac)

These scripts are for a **real Mac**. Timings they produce are Mac-to-Mac
only when both C and Zig ran on that same machine. Cloud VM numbers in
`artifacts/c-baseline/` and `artifacts/zig-bench/` are **not** local Mac
results.

Official Zig **0.17.1** (latest 0.17 stable, 2026-11-02):
https://ziglang.org/download/

- `0.17.1` and `0.17.0` are the official 0.17 releases (`https://ziglang.org/download/index.json`)
- Release notes live at `https://ziglang.org/download/0.17.0/release-notes.html` (0.17.1 points there)
- `master` is **0.18.0-dev** — do not use it; call it a dev build if you do

Frozen C collector sources stay at SHA `21f34a960f8b56d1dcdf1ab55b8e5e14e4e8ff31`.
This host stub is not a collector edit.

## Commands (from repo root, on the Mac)

```sh
# 1. Official 0.17.1 toolchain (aarch64 or x86_64)
./scripts/macos/install-zig-0.17.1.sh

# 2. Unchanged C collectors, as-is, native clang
./scripts/macos/c-baseline.sh

# 3. Zig 0.17.1 Debug + ReleaseFast native regression
./scripts/macos/zig-regression.sh

# 4. Zig 0.17.1 optimized ops (same N / interleaving as C)
./scripts/macos/zig-bench.sh

# 5. Raw-format comparison (C vs Zig from this Mac only)
python3 scripts/macos/compare.py \
  artifacts/macos-local/c/logs/ops-raw.txt \
  artifacts/macos-local/zig/logs/ops-raw.txt
```

Outputs go to `artifacts/macos-local/` (not the frozen Linux VM baseline).

## Kotlin benches

`bench/micro.sh`, `bench/compare.sh`, and `tests/kt` still need `newkotlinc`.
That is an explicit remaining blocker, not a claimed baseline.
