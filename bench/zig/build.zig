const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const o = b.addOptions();
    o.addOption([]const u8, "root", b.option([]const u8, "root", "KotlinX repository root (default: nearest parent of the cwd with bin/newkotlinc)") orelse "");
    o.addOption(usize, "runs", b.option(usize, "runs", "Measured runs per benchmark, median taken (default 5)") orelse 5);
    o.addOption(f64, "noise", b.option(f64, "noise", "Measurement noise margin on top of every limit (default 0.03)") orelse 0.03);
    o.addOption(f64, "allow", b.option(f64, "allow", "Allowed regression where epoch strongly beats Boehm (default 0.05)") orelse 0.05);
    o.addOption(f64, "strong_ratio", b.option(f64, "strong-ratio", "boehm/epoch baseline ratio that counts as 'strongly beats' (default 1.5)") orelse 1.5);
    o.addOption(f64, "pause_slack_ms", b.option(f64, "pause-slack", "Absolute slack for max-pause limits, ms (default 0.1)") orelse 0.1);
    o.addOption(f64, "better", b.option(f64, "better", "Improvement that triggers a 'refresh baselines' note (default 0.05)") orelse 0.05);
    o.addOption(f64, "load_warn", b.option(f64, "load-warn", "Warn when the 1-min load average exceeds this (default 4)") orelse 4);
    o.addOption(bool, "boehm", b.option(bool, "boehm", "Also measure Boehm for every benchmark (default: only cyclic_garbage)") orelse false);
    o.addOption([]const u8, "only", b.option([]const u8, "only", "Comma-separated benchmark names to run (default: all)") orelse "");
    o.addOption([]const u8, "commit", b.option([]const u8, "commit", "Commit recorded by update-baselines") orelse "unknown");

    const mod = b.createModule(.{ .root_source_file = b.path("gc_bench_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    mod.addOptions("bench_options", o);
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true; // always re-measure
    b.step("test", "Run the GC regression benchmarks (fails on a threshold violation)").dependOn(&run_tests.step);

    const umod = b.createModule(.{ .root_source_file = b.path("update_baselines.zig"), .target = target, .optimize = optimize, .link_libc = true });
    umod.addOptions("bench_options", o);
    const upd = b.addExecutable(.{ .name = "update-baselines", .root_module = umod });
    b.installArtifact(upd); // `zig build` compiles it without running
    const run_upd = b.addRunArtifact(upd);
    run_upd.has_side_effects = true;
    b.step("update-baselines", "Measure epoch and Boehm and rewrite baselines.zon").dependOn(&run_upd.step);
}
