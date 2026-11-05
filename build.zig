//! Native Zig build for the KotlinX GC port.
//! Requires Zig 0.14.1 (also verified to need libc).
//!
//!   zig build                        # compile every collector's test + bench binaries
//!   zig build test                   # run native regression for all collectors (ReleaseSafe)
//!   zig build test -Dgc=perceus      # one collector
//!   zig build bench                  # optimized ops benches (ReleaseFast + LTO)
//!   zig build bench -Dgc=epoch -Doptimize=ReleaseFast
const std = @import("std");

const all_gcs = [_][]const u8{ "rc", "perceus", "incremental", "epoch" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const only = b.option([]const u8, "gc", "Collector to build/test (default: all)");

    const kxgc = b.addModule("kxgc", .{ .root_source_file = b.path("src/kxgc.zig") });
    const host = b.addModule("host", .{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const test_step = b.step("test", "Run native Zig GC regression for selected collectors");
    const bench_step = b.step("bench", "Build and run native ops benches (ReleaseFast)");
    const bench_opt = if (optimize == .Debug) .ReleaseFast else optimize;

    for (all_gcs) |g| {
        if (only) |want| if (!std.mem.eql(u8, want, g)) continue;

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
            .root_source_file = b.path("tests/native/suite.zig"),
            .target = target,
            .optimize = optimize,
        });
        suite.root_module.addImport("collector", coll);
        suite.root_module.addImport("kxgc", kxgc);
        suite.root_module.addImport("host", host);
        suite.linkLibC();
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
        bcoll.addImport("host", host);

        const ops = b.addExecutable(.{
            .name = b.fmt("gc-ops-{s}", .{g}),
            .root_source_file = b.path("bench/native/ops.zig"),
            .target = target,
            .optimize = bench_opt,
        });
        ops.root_module.addImport("collector", bcoll);
        ops.root_module.addImport("kxgc", kxgc);
        ops.root_module.addImport("host", host);
        ops.linkLibC();
        ops.want_lto = true;
        b.installArtifact(ops);

        const run_ops = b.addRunArtifact(ops);
        if (b.args) |args| run_ops.addArgs(args);
        run_ops.has_side_effects = true;
        bench_step.dependOn(&run_ops.step);
    }

}
