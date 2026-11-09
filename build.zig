//! Native Zig build for the KotlinX GC port.
//! Requires official Zig 0.17.1 (https://ziglang.org/download/ dated 2026-11-02).
//! Do not use 0.18.0-dev (master).
//!
//!   zig build                        # compile every collector's test + bench binaries
//!   zig build test                   # run native regression for all collectors
//!   zig build test -Dgc=perceus      # one collector
//!   zig build bench                  # optimized ops benches (ReleaseFast; LTO on ELF/COFF only)
const std = @import("std");

const all_gcs = [_][]const u8{ "rc", "perceus", "incremental", "epoch" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const only = b.option([]const u8, "gc", "Collector to build/test (default: all)");
    const bench_options = b.addOptions();
    bench_options.addOption(usize, "object_size", b.option(usize, "bench-object-size", "Ops object bytes (minimum 40; default 40)") orelse 40);
    bench_options.addOption(usize, "live_count", b.option(usize, "bench-live", "Ops live objects (power of two; default 65536)") orelse 65536);

    const kxgc = b.addModule("kxgc", .{ .root_source_file = b.path("src/kxgc.zig") });
    const host = b.addModule("host", .{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const test_step = b.step("test", "Run native Zig GC regression for selected collectors");
    const bench_step = b.step("bench", "Build and run native ops benches (ReleaseFast)");
    const bench_opt: std.builtin.Optimize = if (optimize == .debug) .fast else optimize;
    // Zig 0.17.1: LLVM LTO needs LLD. The self-hosted Mach-O linker cannot do LLVM LTO
    // ("error: LTO requires using LLD"). Keep full LTO on ELF/COFF; keep ReleaseFast on Darwin.
    const ops_lto: std.zig.LtoMode = switch (target.result.ofmt) {
        .elf, .coff, .wasm => .full,
        else => .none,
    };
    const host_fast = b.createModule(.{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = bench_opt,
        .link_libc = true,
    });

    // wasm32-wasi (Node/Bun/Deno/browser via scripts/wasm/run.mjs) is single-threaded: no pthreads,
    // so `epoch` (background collector threads) is not built there.
    const is_wasm = target.result.cpu.arch.isWasm();
    // The shadow stack sits at the bottom of linear memory, so its whole size is resident memory of
    // every wasm instance. Zig's default is 16 MiB; the collectors use explicit work stacks. Optimized
    // tests and benches peak under 32 KiB of it, the Debug test suite near 180 KiB (suite.zig `objRel`
    // recurses down a 1000-object chain), so keep at least 256 KiB for Debug. Overflowing it traps
    // (stack-first layout).
    const wasm_stack = b.option(u64, "wasm-stack-size", "wasm shadow stack bytes (default 1 MiB)") orelse 1 << 20;
    // DWARF is ~94% of an optimized wasm module (1.2 MiB of 1.3 MiB) and engines keep the module bytes.
    const strip_opt = b.option(bool, "strip", "Strip debug info (default: optimized wasm builds)");

    for (all_gcs) |g| {
        if (only) |want| if (!std.mem.eql(u8, want, g)) continue;
        if (is_wasm and std.mem.eql(u8, g, "epoch")) continue;

        const coll = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{g})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        coll.addImport("kxgc", kxgc);
        coll.addImport("host", host);

        const suite = b.addExecutable(.{
            .name = b.fmt("gc-test-{s}", .{g}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/native/suite.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .strip = if (strip_opt) |v| v else if (is_wasm and optimize != .debug) true else null,
                .imports = &.{
                    .{ .name = "collector", .module = coll },
                    .{ .name = "kxgc", .module = kxgc },
                    .{ .name = "host", .module = host },
                },
            }),
        });
        if (is_wasm) suite.stack_size = wasm_stack;
        b.installArtifact(suite);

        const run = b.addRunArtifact(suite);
        run.has_side_effects = true;
        test_step.dependOn(&run.step);

        const bcoll = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{g})),
            .target = target,
            .optimize = bench_opt,
            .link_libc = true,
        });
        bcoll.addImport("kxgc", kxgc);
        bcoll.addImport("host", host_fast);

        const ops = b.addExecutable(.{
            .name = b.fmt("gc-ops-{s}", .{g}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/native/ops.zig"),
                .target = target,
                .optimize = bench_opt,
                .link_libc = true,
                .strip = if (strip_opt) |v| v else if (is_wasm) true else null,
                .imports = &.{
                    .{ .name = "collector", .module = bcoll },
                    .{ .name = "kxgc", .module = kxgc },
                    .{ .name = "host", .module = host_fast },
                },
            }),
        });
        ops.lto = ops_lto;
        if (is_wasm) ops.stack_size = wasm_stack;
        ops.root_module.addOptions("bench_options", bench_options);
        b.installArtifact(ops);

        const run_ops = b.addRunArtifact(ops);
        run_ops.addPassthruArgs();
        run_ops.has_side_effects = true;
        bench_step.dependOn(&run_ops.step);

        // Cycle-collector workload (perceus / incremental; epoch and rc print "skipped"), and size-class
        // phases (peak memory when memory freed by one size class must serve the next), and random churn
        // (free and replace objects in random order).
        for ([_][]const u8{ "cycles", "phases", "churn" }) |bench| {
            const exe = b.addExecutable(.{
                .name = b.fmt("gc-{s}-{s}", .{ bench, g }),
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("bench/native/{s}.zig", .{bench})),
                    .target = target,
                    .optimize = bench_opt,
                    .link_libc = true,
                    .strip = if (strip_opt) |v| v else if (is_wasm) true else null,
                    .imports = &.{
                        .{ .name = "collector", .module = bcoll },
                        .{ .name = "kxgc", .module = kxgc },
                        .{ .name = "host", .module = host_fast },
                    },
                }),
            });
            exe.lto = ops_lto;
            if (is_wasm) exe.stack_size = wasm_stack;
            b.installArtifact(exe);
        }
    }
}
