//! Mass death under deferred RC (`epoch`): a chain of `live` objects is dropped at once while the
//! program keeps allocating. The collector returns the whole chain to the mutator, which frees it at
//! its epoch boundaries: the pause of a boundary must not grow with the number of objects returned.
//!   gc-drop-<gc> [live=1000000] [rounds=4] [churn=2000000]
//! Each round builds the chain, drops its head, then allocates and drops `churn` objects.
const std = @import("std");
const gc = @import("collector");
const kx = @import("kxgc");
const host = @import("host");

const Obj = extern struct {
    hdr: u64,
    vt: *kx.VTab,
    prev: ?*Obj,
    next: ?*Obj,
    val: i64,
};

var freed: u64 = 0;

fn objFree(p: ?*anyopaque) callconv(.c) void {
    freed += 1;
    gc.freeTrace(p, @sizeOf(Obj));
}
fn objTrav(p: ?*anyopaque, f: ?kx.VisitFn) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(p));
    f.?(o.prev);
    f.?(o.next);
}
fn objRelo(_: ?*anyopaque) callconv(.c) void {}
fn objRel(p: ?*anyopaque) callconv(.c) void {
    gc.logDec(p);
}

var vt: kx.VTab = .{ .rel = objRel, .trav = objTrav, .relo = objRelo, .freemem = objFree, .cyclic = @ptrFromInt(1) };

fn newObj(v: i64) *Obj {
    const o: *Obj = @ptrCast(@alignCast(gc.allocTrace(@sizeOf(Obj)).?));
    o.hdr = 1;
    o.vt = &vt;
    o.prev = null;
    o.next = null;
    o.val = v;
    return o;
}

fn arg(argv: []const [*:0]const u8, i: usize, default: usize) !usize {
    return if (argv.len > i) std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) else default;
}

pub fn main(init: std.process.Init.Minimal) !void {
    if (comptime !gc.caps.deferred) {
        _ = std.c.printf("%s drop skipped (needs deferred RC)\n", gc.rt_gc_name());
        return;
    }
    const argv = init.args.vector;
    const live = try arg(argv, 1, 1_000_000);
    const rounds = try arg(argv, 2, 4);
    const churn = try arg(argv, 3, 2_000_000);
    var sink: i64 = 0;
    const t0 = host.rt_nanos();
    for (0..rounds) |_| {
        // head -> ... -> tail, each node owned by its predecessor only
        var head: ?*Obj = null;
        for (0..live) |i| {
            const o = newObj(@intCast(i));
            @atomicStore(?*Obj, &o.next, head, .release); // takes over the reference `head` held
            gc.writeBarrier(o);
            head = o;
        }
        gc.logDec(head); // the whole chain dies
        for (0..churn) |i| {
            const o = newObj(@intCast(i));
            sink +%= o.val;
            gc.logDec(o);
        }
    }
    const ns: f64 = @floatFromInt(host.rt_nanos() - t0);
    // Mutator phase only: the exit drain below is not a mutator pause.
    const max_us = @as(f64, @floatFromInt(host.pausePercentileNs(1.0))) / 1e3;
    const p99_us = @as(f64, @floatFromInt(host.pausePercentileNs(0.99))) / 1e3;
    const p999_us = @as(f64, @floatFromInt(host.pausePercentileNs(0.999))) / 1e3;
    const rss = host.peakRssKb();
    gc.rt_gc_collect();
    const want: u64 = @intCast(rounds * (live + churn));
    _ = std.c.printf(
        "%s drop ns_per_obj %.2f pause_max_us %.1f pause_p999_us %.1f pause_p99_us %.1f peak_rss_kb %lld freed_ok %d sink %lld\n",
        gc.rt_gc_name(),
        ns / @as(f64, @floatFromInt(want)),
        max_us,
        p999_us,
        p99_us,
        @as(c_longlong, rss),
        @as(c_int, @intFromBool(freed == want)),
        @as(c_longlong, sink),
    );
    if (freed != want) host.rt_panic("drop bench: garbage not reclaimed");
}
