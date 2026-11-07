# Native Zig GC tests

These tests drive the **Zig collectors** in `src/`, not the C files.
They port `tests/archive/unit/gc_unit.c`, `tests/zig/src/unit/api_test.zig`,
`tests/archive/unit/traversal.c`, and `tests/archive/incremental/one_pass.c`.

```sh
# Official Zig 0.17.1
zig build test                 # all collectors
zig build test -Dgc=epoch
zig build --release=fast && ./zig-out/bin/gc-test-perceus
```

`tests/zig/` remains the historical harness that links **C** collectors.
