# Native Zig GC tests

These tests drive the **Zig collectors** in `src/`, not the C files.
They port `tests/archive/unit/gc_unit.c`, `tests/zig/src/unit/api_test.zig`,
`tests/archive/unit/traversal.c`, `tests/archive/incremental/one_pass.c`, and the scenario of
`tests/incremental/slice_black.kt` (live root scanned black by an earlier slice, then released).

```sh
# Official Zig 0.17.1
zig build test                 # all collectors
zig build test -Dgc=epoch
zig build --release=fast && ./zig-out/bin/gc-test-perceus

# wasm32-wasi under a JS engine (rc, perceus, incremental; epoch needs threads)
zig build -Dtarget=wasm32-wasi
node scripts/wasm/run.mjs zig-out/bin/gc-test-incremental.wasm
```

`tests/zig/` remains the historical harness that links **C** collectors.
