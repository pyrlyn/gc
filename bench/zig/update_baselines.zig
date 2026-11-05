//! `zig build update-baselines`: measures every benchmark (epoch and Boehm) and rewrites baselines.zon.
//! Run it only on a known-good main (see README.md, "Refreshing baselines"); review the diff and commit it.
const std = @import("std");
const h = @import("harness.zig");
const opts = @import("bench_options");
const old: h.Baselines = @import("baselines.zon");

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(p: [*]const u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) c_int;
extern "c" fn time(t: ?*i64) i64;

fn opt(a: std.mem.Allocator, key: []const u8, v: ?f64) ![]const u8 {
    return if (v) |x| std.fmt.allocPrint(a, " .{s} = {d:.3},", .{ key, x }) else "";
}

fn metrics(a: std.mem.Allocator, b: h.Bench, m: h.Measured) ![]const u8 {
    // Keep the same metric set as before (e.g. no pause for allocation-only benches, time only for suite).
    const t = try opt(a, "time_ms", if (b.epoch.time_ms != null) m.time_ms else null);
    const r = try opt(a, "rss_mib", if (b.epoch.rss_mib != null) m.rss_mib else null);
    const p = try opt(a, "pause_max_ms", if (b.epoch.pause_max_ms != null) m.pause_max_ms else null);
    return std.fmt.allocPrint(a, ".{{{s}{s}{s} }}", .{ t, r, p });
}

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const a = arena.allocator();
    const cfg: h.Config = .{ .root = try h.repoRoot(a, opts.root), .runs = opts.runs };
    var out: std.ArrayList(u8) = .empty;
    const l = h.loadAvg();
    try out.appendSlice(a, "// Known-good epoch GC baselines (and Boehm reference numbers) for bench/gc/zig.\n// Written by `zig build update-baselines`; see README.md, \"Refreshing baselines\".\n.{\n");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "    .provenance = \"update-baselines, unix time {d}, commit {s}, median of {d}, load {d:.1} {d:.1} {d:.1}\",\n", .{ time(null), opts.commit, cfg.runs, l[0], l[1], l[2] }));
    var cyc_boehm: f64 = old.cyclic_rss_target_mib;
    var body: std.ArrayList(u8) = .empty;
    for (old.benches) |b| {
        std.debug.print("measuring {s} ...\n", .{b.name});
        const e = try h.measure(a, cfg, b, "epoch");
        const bo = try h.measure(a, cfg, b, "boehm");
        if (std.mem.eql(u8, b.name, "cyclic_garbage")) cyc_boehm = bo.rss_mib;
        std.debug.print("  epoch {d:.2} ms {d:.2} MiB {d:.3} ms | boehm {d:.2} ms {d:.2} MiB {d:.3} ms\n", .{ e.time_ms, e.rss_mib, e.pause_max_ms orelse 0, bo.time_ms, bo.rss_mib, bo.pause_max_ms orelse 0 });
        try body.appendSlice(a, try std.fmt.allocPrint(a, "        .{{ .name = \"{s}\", .category = \"{s}\", .kind = .{s}, .source = \"{s}\",\n           .epoch = {s}, .boehm = {s} }},\n", .{ b.name, b.category, @tagName(b.kind), b.source, try metrics(a, b, e), try metrics(a, b, bo) }));
    }
    // The cyclic RSS target is Boehm's peak; it only ever tightens (never loosened by a noisy Boehm run).
    try out.appendSlice(a, try std.fmt.allocPrint(a, "    .cyclic_rss_target_mib = {d:.2},\n    .benches = .{{\n", .{@min(cyc_boehm, old.cyclic_rss_target_mib)}));
    try out.appendSlice(a, body.items);
    try out.appendSlice(a, "    },\n}\n");
    const path = try std.fmt.allocPrintSentinel(a, "{s}/bench/gc/zig/baselines.zon", .{cfg.root}, 0);
    const f = fopen(path.ptr, "w") orelse return error.OpenFailed;
    _ = fwrite(out.items.ptr, 1, out.items.len, f);
    _ = fclose(f);
    std.debug.print("wrote {s}; review `git diff` and commit it\n", .{path});
}
