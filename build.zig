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
                .imports = &.{
                    .{ .name = "collector", .module = coll },
                    .{ .name = "kxgc", .module = kxgc },
                    .{ .name = "host", .module = host },
                },
            }),
        });
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
                .imports = &.{
                    .{ .name = "collector", .module = bcoll },
                    .{ .name = "kxgc", .module = kxgc },
                    .{ .name = "host", .module = host_fast },
                },
            }),
        });
        ops.lto = ops_lto;
        ops.root_module.addOptions("bench_options", bench_options);
        b.installArtifact(ops);

        const run_ops = b.addRunArtifact(ops);
        run_ops.addPassthruArgs();
        run_ops.has_side_effects = true;
        bench_step.dependOn(&run_ops.step);

        // Cycle-collector workload (perceus / incremental); epoch and rc print "skipped".
        const cycles = b.addExecutable(.{
            .name = b.fmt("gc-cycles-{s}", .{g}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/native/cycles.zig"),
                .target = target,
                .optimize = bench_opt,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "collector", .module = bcoll },
                    .{ .name = "kxgc", .module = kxgc },
                    .{ .name = "host", .module = host_fast },
                },
            }),
        });
        cycles.lto = ops_lto;
        b.installArtifact(cycles);
    }
}
