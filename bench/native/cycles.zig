//! Cycle-collector workload: per-cycle cost, pauses and root-buffer backlog of the synchronous
//! cycle collectors (`perceus`, `incremental`). Runs natively and as wasm32-wasi under a JS host
//! (`scripts/wasm/run.mjs`).
//!
//!   gc-cycles-<gc> [N] [scenario]
//!
//! Pause max / p99 are process-wide, so pass one scenario per process (bench/native/cycles.sh).
//! Each iteration builds a garbage 2-cycle a <-> b and drops it (one possible root). With a live
//! ring of L objects, `a` also points into the ring, so trial deletion from `a` re-traces the ring:
//! the cost of a slice is then dominated by the graph its roots share, not by the roots themselves.
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
    const o: *Obj = @ptrCast(@alignCast(p orelse return));
    const c1 = o.hdr -% 1;
    if (c1 & kx.CNT_MASK != 0) {
        o.hdr = c1 | (@as(u64, kx.PURPLE) << kx.COLOR_SHIFT);
        if (c1 & kx.BUF_BIT != 0) return;
        gc.rt_cc_possible_root(p);
        return;
    }
    o.hdr = c1;
    objRel(o.prev);
    objRel(o.next);
    gc.rt_cc_dead(p);
}

var vt: kx.VTab = .{ .rel = objRel, .trav = objTrav, .relo = objRelo, .freemem = objFree, .cyclic = @ptrFromInt(1) };

fn newObj(v: i64) *Obj {
    const o: *Obj = @ptrCast(@alignCast(gc.allocTrace(@sizeOf(Obj)).?));
    o.* = .{ .hdr = 1, .vt = &vt, .prev = null, .next = null, .val = v };
    return o;
}

const Scenario = struct { name: [:0]const u8, live: usize };
const scenarios = [_]Scenario{
    .{ .name = "garbage", .live = 0 }, // independent garbage cycles
    .{ .name = "shared_1k", .live = 1_000 }, // roots share a small live graph
    .{ .name = "shared_20k", .live = 20_000 }, // shared live graph ~ one budget per trace
    .{ .name = "shared_200k", .live = 200_000 }, // shared graph far over budget per trace
};

fn run(s: Scenario, n: usize) void {
    var ring: []*Obj = &.{};
    if (s.live != 0) {
        const raw = gc.rt_gc_mem_alloc(@sizeOf(*Obj) * s.live).?;
        ring = @as([*]*Obj, @ptrCast(@alignCast(raw)))[0..s.live];
        for (ring, 0..) |*r, i| r.* = newObj(@intCast(i));
        for (ring, 0..) |r, i| {
            const nx = ring[(i + 1) % s.live];
            nx.hdr += 1;
            r.next = nx;
        }
    }
    freed = 0;
    var before: kx.Stats = undefined;
    gc.rt_gc_stats(&before);
    var max_backlog: usize = 0;
    const t0 = host.rt_nanos();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a = newObj(@intCast(i));
        const b = newObj(@intCast(i));
        a.next = b; // takes b's reference
        b.next = a;
        a.hdr += 1;
        if (ring.len != 0) {
            const r = ring[i % ring.len];
            r.hdr += 1;
            a.prev = r;
        }
        objRel(a); // a <-> b is now unreachable: one possible root
        if (comptime @hasDecl(gc, "debugRootsLen")) max_backlog = @max(max_backlog, gc.debugRootsLen());
    }
    const t_mut = host.rt_nanos() - t0;
    var st: kx.Stats = undefined;
    gc.rt_gc_stats(&st); // mutator phase only: the final drain is not a mutator pause
    const p99 = host.pausePercentileNs(0.99);
    gc.rt_gc_collect();
    const t_drain = host.rt_nanos() - t0 - t_mut;
    const ok = freed == 2 * n;
    _ = std.c.printf(
        "%s %s ns_per_cycle %.1f collections %lld pause_max_us %.1f pause_p99_us %.1f drain_ms %.2f backlog_max %zu freed_ok %d\n",
        gc.rt_gc_name(),
        s.name.ptr,
        @as(f64, @floatFromInt(t_mut)) / @as(f64, @floatFromInt(n)),
        @as(c_longlong, st.collections - before.collections),
        @as(f64, @floatFromInt(st.pause_ns_max)) / 1e3,
        @as(f64, @floatFromInt(p99)) / 1e3,
        @as(f64, @floatFromInt(t_drain)) / 1e6,
        max_backlog,
        @as(c_int, @intFromBool(ok)),
    );
    if (!ok) host.rt_panic("cycles bench: garbage not reclaimed");
    if (ring.len != 0) {
        // Unlink the ring without creating possible roots, then each node dies by plain RC
        // (no recursive chain release, which would overflow a wasm stack at 200k).
        for (ring) |r| {
            r.next.?.hdr -= 1;
            r.next = null;
        }
        for (ring) |r| objRel(r);
        gc.rt_gc_collect();
        gc.rt_gc_mem_free(@ptrCast(ring.ptr));
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    if (comptime gc.caps.deferred or !gc.caps.cycles) {
        _ = std.c.printf("%s cycles skipped (needs a synchronous cycle collector)\n", gc.rt_gc_name());
        return;
    }
    const argv = init.args.vector;
    const n: usize = if (argv.len > 1) try std.fmt.parseInt(usize, std.mem.span(argv[1]), 10) else 1_000_000;
    const only: ?[]const u8 = if (argv.len > 2) std.mem.span(argv[2]) else null;
    for (scenarios) |s| {
        if (only) |want| if (!std.mem.eql(u8, want, s.name)) continue;
        run(s, n);
    }
    _ = std.c.printf("%s peak_rss_kb %lld\n", gc.rt_gc_name(), @as(c_longlong, host.peakRssKb()));
}
