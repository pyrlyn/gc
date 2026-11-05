//! `zig build test`: one test per benchmark category; each fails loudly on a GC regression.
const std = @import("std");
const h = @import("harness.zig");
const checks = @import("checks.zig");
const opts = @import("bench_options");
const baselines: h.Baselines = @import("baselines.zon");

fn policy() checks.Policy {
    return .{ .strong_ratio = opts.strong_ratio, .allow = opts.allow, .noise = opts.noise, .pause_slack_ms = opts.pause_slack_ms, .better = opts.better };
}

fn selected(name: []const u8) bool {
    if (opts.only.len == 0) return true;
    var it = std.mem.splitScalar(u8, opts.only, ',');
    while (it.next()) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

// The Zig 0.17 test runner may run tests concurrently; benchmarks must not overlap, so each category
// holds this lock for its whole run.
var bench_lock = std.atomic.Value(bool).init(false);
extern "c" fn usleep(us: c_uint) c_int;

fn runCategory(names: []const []const u8) !void {
    while (bench_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) _ = usleep(10_000);
    defer bench_lock.store(false, .release);
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: h.Config = .{ .root = try h.repoRoot(a, opts.root), .runs = opts.runs };
    var failures: usize = 0;
    var ran: usize = 0;
    for (names) |n| {
        if (!selected(n)) continue;
        ran += 1;
        const b = h.findBench(baselines, n) orelse return error.NoBaseline;
        const l = h.loadAvg();
        const m = try h.measure(a, cfg, b, "epoch");
        const want_boehm = opts.boehm or std.mem.eql(u8, n, "cyclic_garbage");
        const bm: ?h.Measured = if (want_boehm) try h.measure(a, cfg, b, "boehm") else null;
        std.debug.print("\n== {s} ({s}), median of {d}, load {d:.1} {d:.1} {d:.1}: epoch {d:.2} ms, {d:.2} MiB, max pause {d:.3} ms", .{ n, b.category, cfg.runs, l[0], l[1], l[2], m.time_ms, m.rss_mib, m.pause_max_ms orelse 0 });
        if (bm) |x| std.debug.print(" | boehm {d:.2} ms, {d:.2} MiB, max pause {d:.3} ms", .{ x.time_ms, x.rss_mib, x.pause_max_ms orelse 0 });
        std.debug.print("\n", .{});
        failures += checks.check(policy(), baselines, b, m, bm).failures;
    }
    if (ran > 0 and opts.load_warn > 0 and h.loadAvg()[0] > opts.load_warn)
        std.debug.print("note: load average {d:.1} > {d:.0}; timings may be noisy (raise -Dnoise or rerun on a quiet machine)\n", .{ h.loadAvg()[0], opts.load_warn });
    if (failures > 0) {
        std.debug.print("!!! {d} GC threshold violation(s) above\n", .{failures});
        return error.GcRegression;
    }
}

test "allocation: alloc_throughput, short_lived, suite alloc" {
    try runCategory(&.{ "alloc_throughput", "short_lived", "alloc" });
}
test "big live heaps: live_heap_churn, big_live_churn, huge_live_churn" {
    try runCategory(&.{ "live_heap_churn", "big_live_churn", "huge_live_churn" });
}
test "bigheap: suite bigheap" {
    try runCategory(&.{"bigheap"});
}
test "cyclic garbage: cyclic_garbage (peak RSS <= Boehm), suite cycles" {
    try runCategory(&.{ "cyclic_garbage", "cycles" });
}
test "LRU: suite lru" {
    try runCategory(&.{"lru"});
}
test "wide graph: wide_graph_churn" {
    try runCategory(&.{"wide_graph_churn"});
}
