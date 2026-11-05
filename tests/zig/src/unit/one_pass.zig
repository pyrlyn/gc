//! Port of compiler/gc/tests/incremental/one_pass.c. Run with KX_GC_BUDGET_US=0: every step is over budget
//! on its first slice and must finish in one pass. The roots are garbage cycles that all point into one
//! live ring. A live root is dropped once a slice has scanned it black, but these stay PURPLE, so each
//! further 64-root slice would re-trace the whole ring.
const kx = @import("kx.zig");
const c = kx.c;

const RING = 20000;
const ROOTS = 12000;
const MAX_TRAV = 10 * RING;

const Obj = extern struct { hdr: u64, vt: *c.KxVTab, a: ?*Obj, b: ?*Obj };
var trav_calls: i64 = 0;
var freed: i64 = 0;
fn objTrav(p: ?*anyopaque, f: c.kx_visit_fn) callconv(.c) void {
    trav_calls += 1;
    const o: *Obj = @ptrCast(@alignCast(p));
    f.?(o.a);
    f.?(o.b);
}
fn objRelo(_: ?*anyopaque) callconv(.c) void {}
fn objFree(p: ?*anyopaque) callconv(.c) void {
    freed += 1;
    c.rt_free_trace(p, @sizeOf(Obj));
}
var vt: c.KxVTab = .{ .rel = null, .trav = objTrav, .relo = objRelo, .freemem = objFree, .cyclic = @ptrFromInt(1) };
fn newObj(count: u64) *Obj {
    const o: *Obj = @ptrCast(@alignCast(c.rt_alloc_trace(@sizeOf(Obj))));
    o.* = .{ .hdr = count, .vt = &vt, .a = null, .b = null };
    return o;
}

var ring: [RING]*Obj = undefined;

export fn main() c_int {
    for (0..RING) |i| ring[i] = newObj(2); // the array's reference + the previous node's
    for (0..RING) |i| ring[i].a = ring[(i + 1) % RING];
    for (0..ROOTS) |_| {
        const g = newObj(2); // the local reference + its own a
        g.a = g;
        g.b = ring[0];
        ring[0].hdr += 1;
        g.hdr -= 1;
        c.rt_cc_possible_root(g);
    }
    c.rt_gc_collect();
    if (freed != ROOTS or (ring[0].hdr & kx.CNT_MASK) != 2 or trav_calls > MAX_TRAV) {
        _ = c.fprintf(kx.stderrFile(), "freed=%lld of %d, ring[0] count=%llu, trav=%lld (max %d)\n", @as(c_longlong, freed), @as(c_int, ROOTS), @as(c_ulonglong, ring[0].hdr & kx.CNT_MASK), @as(c_longlong, trav_calls), @as(c_int, MAX_TRAV));
        return 1;
    }
    return 0;
}
