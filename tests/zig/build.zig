//! Zig GC test suite (see README.md).
//!   zig build gc        - run the whole suite (ported run.sh cases + new gc-api tests), fails on any FAIL
//!   zig build mt        - only the multithreaded collector tests (gc-mt, plain -O1/-O3 + TSan builds)
//!   zig build ported    - only the cases ported from run.sh (output comparable line by line with run.sh)
//!   zig build test      - unit tests of the suite's own helpers
//!   zig build coverage  - suite built with clang source-based coverage; llvm-cov summary + HTML in coverage/
//! Options: -Dgcs="perceus epoch" restricts collectors (same as GCS= for run.sh).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // The objects are linked by the system clang, which targets the SDK's major version; keep Zig's
    // minimum below it (otherwise ld warns "built for newer macOS version").
    const obj_target = if (target.result.os.tag == .macos) b.resolveTargetQuery(.{
        .cpu_arch = target.result.cpu.arch,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } },
    }) else target;
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const gcs = b.option([]const u8, "gcs", "Collectors to test (default: every compiler/gc/*/gc.c)");

    // Unit-level tests are Zig objects that export main(); the runner links each with runtime.c and one
    // collector using the C compiler and flags run.sh used (incl. -O1/-O3 and ASan builds).
    const objs = [_][]const u8{ "gc_unit", "traversal", "one_pass", "api_test", "mt_test" };
    const install_objs = b.step("objs", "Build the unit-test objects");
    for (objs) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/unit/{s}.zig", .{name})),
            .target = obj_target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        });
        mod.addIncludePath(b.path("../.."));
        const obj = b.addObject(.{ .name = name, .root_module = mod });
        obj.bundle_compiler_rt = true;
        const inst = b.addInstallFile(obj.getEmittedBin(), b.fmt("obj/{s}.o", .{name}));
        install_objs.dependOn(&inst.step);
    }
    b.getInstallStep().dependOn(install_objs);

    const rmod = b.createModule(.{ .root_source_file = b.path("src/runner.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const runner = b.addExecutable(.{ .name = "gc-suite", .root_module = rmod });
    b.installArtifact(runner);

    const obj_dir = b.getInstallPath(.prefix, "obj");
    const repo = b.path("../../../..");
    inline for (.{ .{ "gc", "Run the Zig GC test suite", "" }, .{ "ported", "Run only the cases ported from run.sh", "--ported-only" }, .{ "mt", "Run only the multithreaded collector tests (plain + TSan)", "--mt-only" } }) |s| {
        const run = b.addRunArtifact(runner);
        run.setCwd(repo);
        run.addArgs(&.{ "--obj", obj_dir });
        if (s[2].len > 0) run.addArg(s[2]);
        if (gcs) |g| run.setEnvironmentVariable("GCS", g);
        run.has_side_effects = true;
        run.stdio = .inherit;
        run.step.dependOn(b.getInstallStep());
        b.step(s[0], s[1]).dependOn(&run.step);
    }

    const cov = b.addSystemCommand(&.{ "sh", "coverage.sh" });
    cov.setCwd(b.path("."));
    cov.addArgs(&.{ b.getInstallPath(.bin, "gc-suite"), obj_dir });
    if (gcs) |g| cov.setEnvironmentVariable("GCS", g);
    cov.has_side_effects = true;
    cov.stdio = .inherit;
    cov.step.dependOn(b.getInstallStep());
    b.step("coverage", "Run the suite with clang coverage; summary + HTML in coverage/").dependOn(&cov.step);

    const tmod = b.createModule(.{ .root_source_file = b.path("src/runner.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const t = b.addTest(.{ .root_module = tmod });
    b.step("test", "Unit tests of the suite helpers").dependOn(&b.addRunArtifact(t).step);
}
