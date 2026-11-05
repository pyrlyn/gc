//! Native Zig regression suite: ports of archive/unit/gc_unit.c, tests/zig api_test,
//! archive/unit/traversal.c (perceus/incremental) and archive/incremental/one_pass.c.
const std = @import("std");
const gc = @import("collector");
const kx = @import("kxgc");
const host = @import("host");

const Obj = extern struct {
    hdr: u64,
    vt: *kx.VTab,
    next: ?*Obj,
    val: i64,
};

var freed: i64 = 0;
var relo_calls: i64 = 0;
var fails: u32 = 0;

fn objFree(p: ?*anyopaque) callconv(.c) void {
    freed += 1;
    gc.rt_free_trace(p, @sizeOf(Obj));
}
fn objTrav(p: ?*anyopaque, f: ?kx.VisitFn) callconv(.c) void {
    f.?(@as(*Obj, @ptrCast(@alignCast(p))).next);
}
fn objRelo(_: ?*anyopaque) callconv(.c) void {
    relo_calls += 1;
}
fn objRel(p: ?*anyopaque) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(p orelse return));
    const c1 = o.hdr -% 1;
    if (c1 & kx.CNT_MASK != 0) {
        if (c1 & kx.BUF_BIT != 0) {
            o.hdr = c1 | (@as(u64, 3) << kx.COLOR_SHIFT);
            return;
        }
        o.hdr = c1;
        gc.rt_cc_possible_root(p);
        return;
    }
    o.hdr = c1;
    objRel(o.next);
    objRelo(p);
    if (o.hdr & kx.BUF_BIT != 0) {
        o.hdr &= ~(@as(u64, 3) << kx.COLOR_SHIFT);
        return;
    }
    objFree(p);
}

var vt: kx.VTab = .{ .rel = objRel, .trav = objTrav, .relo = objRelo, .freemem = objFree, .cyclic = @ptrFromInt(1) };

fn newObj(v: i64) *Obj {
    const o: *Obj = @ptrCast(@alignCast(gc.rt_alloc_trace(@sizeOf(Obj)).?));
    o.* = .{ .hdr = 1, .vt = &vt, .next = null, .val = v };
    return o;
}
fn countOf(o: *Obj) u64 {
    return o.hdr & kx.CNT_MASK;
}
fn check(cond: bool, what: []const u8) void {
    if (!cond) {
        std.debug.print("FAIL {s}\n", .{what});
        fails += 1;
    }
}

fn acyclicAlloc() void {
    var i: i32 = 0;
    while (i < 100000) : (i += 1) {
        const p: [*]i64 = @ptrCast(@alignCast(gc.rt_alloc(48).?));
        p[0] = 1;
        p[5] = i;
        check(p[5] == i, "acyclic slot");
        gc.rt_free(p, 48);
    }
}

fn acyclicChain() void {
    freed = 0;
    const a = newObj(1);
    const b = newObj(2);
    a.next = b;
    objRel(a);
    check(freed == 2, "acyclic chain freed by RC");
}

fn sharedSurvives() void {
    freed = 0;
    const a = newObj(1);
    a.hdr += 1;
    objRel(a);
    check(freed == 0 and a.val == 1, "shared object survives one release");
    objRel(a);
    gc.rt_gc_collect();
    check(freed == 1, "last release frees shared object");
}

fn reachableCycle() void {
    const a = newObj(10);
    const b = newObj(20);
    a.next = b;
    b.next = a;
    b.hdr += 1;
    a.hdr += 1;
    objRel(a);
    gc.rt_gc_collect();
    check(a.val == 10 and b.val == 20 and a.next == b, "reachable cycle survives");
    if (gc.caps.cycles) {
        freed = 0;
        relo_calls = 0;
        objRel(b);
        var i: u32 = 0;
        while (i < 3) : (i += 1) gc.rt_gc_collect();
        var st: kx.Stats = undefined;
        gc.rt_gc_stats(&st);
        check(st.collections > 0, "cycle collection ran");
        if (gc.caps.precise) check(relo_calls >= 2 or freed >= 2, "cycle reclaimed");
    }
}

fn storageHooks() void {
    const m0: [*]i64 = @ptrCast(@alignCast(gc.rt_gc_mem_calloc(64).?));
    var i: usize = 0;
    while (i < 8) : (i += 1) check(m0[i] == 0, "calloc zero");
    m0[7] = 42;
    const m1: [*]i64 = @ptrCast(@alignCast(gc.rt_gc_mem_realloc(m0, 4096).?));
    check(m1[7] == 42, "realloc keeps prefix");
    gc.rt_gc_mem_free(m1);
    const z = gc.rt_gc_mem_realloc(null, 16);
    check(z != null, "realloc NULL");
    gc.rt_gc_mem_free(z);
}

fn noCollectWhileDraining() void {
    if (!gc.caps.cycles) return;
    const N = 300000;
    const objs = std.heap.page_allocator.alloc(*Obj, N) catch {
        fails += 1;
        return;
    };
    defer std.heap.page_allocator.free(objs);
    var i: usize = 0;
    while (i < N) : (i += 1) {
        objs[i] = newObj(@intCast(i));
        objs[i].hdr += 1;
    }
    var before: kx.Stats = undefined;
    gc.rt_gc_stats(&before);
    host.rt_rel_draining = 1;
    i = 0;
    while (i < N) : (i += 1) objRel(objs[i]);
    host.rt_rel_draining = 0;
    var during: kx.Stats = undefined;
    gc.rt_gc_stats(&during);
    check(during.collections == before.collections, "no collection while rt_rel_draining");
    i = 0;
    while (i < N) : (i += 1) {
        objRel(objs[i]);
        objs[i] = undefined;
    }
    gc.rt_gc_collect();
}

fn selfCycles() void {
    if (!gc.caps.cycles) return;
    var i: i32 = 0;
    while (i < 200000) : (i += 1) {
        const s = newObj(i);
        s.next = s;
        s.hdr += 1;
        objRel(s);
    }
    gc.rt_gc_collect();
    var st: kx.Stats = undefined;
    gc.rt_gc_stats(&st);
    check(st.reclaimed >= 190000, "self cycles reclaimed");
}

fn apiImmediate() void {
    if (gc.caps.deferred) return;
    freed = 0;
    relo_calls = 0;
    var head: ?*Obj = null;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const o = newObj(@intCast(i));
        o.next = head;
        head = o;
    }
    objRel(head);
    check(freed == 1000 and relo_calls == 1000, "1000-chain");
    freed = 0;
    const s = newObj(7);
    i = 0;
    while (i < 10) : (i += 1) s.hdr += 1;
    i = 0;
    while (i < 10) : (i += 1) objRel(s);
    check(countOf(s) == 1 and s.val == 7 and freed == 0, "balanced inc/dec");
    objRel(s);
    gc.rt_gc_collect();
    check(freed == 1, "last release");
}

fn apiTrialDeletion() void {
    if (!gc.caps.cycles or gc.caps.deferred) return;
    freed = 0;
    const R = 100;
    var ring: [R]*Obj = undefined;
    var i: usize = 0;
    while (i < R) : (i += 1) ring[i] = newObj(@intCast(i));
    i = 0;
    while (i < R) : (i += 1) {
        ring[i].next = ring[(i + 1) % R];
        ring[(i + 1) % R].hdr += 1;
    }
    i = 0;
    while (i < R) : (i += 1) objRel(ring[i]);
    i = 0;
    while (i < 3) : (i += 1) gc.rt_gc_collect();
    if (gc.caps.precise) check(freed == R, "garbage ring of 100");
    freed = 0;
    i = 0;
    while (i < R) : (i += 1) ring[i] = newObj(@intCast(i));
    i = 0;
    while (i < R) : (i += 1) {
        ring[i].next = ring[(i + 1) % R];
        ring[(i + 1) % R].hdr += 1;
    }
    i = 1;
    while (i < R) : (i += 1) objRel(ring[i]);
    i = 0;
    while (i < 3) : (i += 1) gc.rt_gc_collect();
    var exact = true;
    i = 0;
    while (i < R) : (i += 1) exact = exact and countOf(ring[i]) == (if (i == 0) @as(u64, 2) else 1) and ring[i].val == @as(i64, @intCast(i));
    check(freed == 0 and exact, "referenced ring survives");
    objRel(ring[0]);
    i = 0;
    while (i < 3) : (i += 1) gc.rt_gc_collect();
    if (gc.caps.precise) check(freed == R, "drop outside reference");
}

fn apiDeferred() void {
    if (!gc.caps.deferred) return;
    gc.rt_gc_collect();
    freed = 0;
    const live = newObj(42);
    gc.rt_gc_log_inc(live);
    gc.rt_gc_log_dec(live);
    gc.rt_gc_collect();
    check(freed == 0 and live.val == 42, "balanced logged inc/dec");
    const a = newObj(1);
    const b = newObj(2);
    a.next = b;
    gc.rt_gc_write_barrier(a);
    gc.rt_gc_log_dec(a);
    gc.rt_gc_collect();
    check(freed == 2, "logged release frees a chain");
    freed = 0;
    const x = newObj(10);
    const y = newObj(20);
    x.next = y;
    gc.rt_gc_write_barrier(x);
    y.next = x;
    gc.rt_gc_log_inc(x);
    gc.rt_gc_write_barrier(y);
    gc.rt_gc_log_dec(x);
    var i: u32 = 0;
    while (i < 3) : (i += 1) gc.rt_gc_collect();
    check(freed == 2, "logged garbage cycle");
    gc.rt_gc_log_dec(live);
    gc.rt_gc_collect();
    check(freed == 3, "last logged release");
}

const FANOUT = 64;
const Node = extern struct {
    hdr: u64,
    vt: *kx.VTab,
    edges: [FANOUT]?*Node,
};
var node_freed: usize = 0;
var node_released: usize = 0;
var node_visits: usize = 0;
fn nodeRel(_: ?*anyopaque) callconv(.c) void {
    @panic("nodeRel");
}
fn nodeFree(p: ?*anyopaque) callconv(.c) void {
    node_freed += 1;
    gc.rt_free_trace(p, @sizeOf(Node));
}
fn nodeRelo(_: ?*anyopaque) callconv(.c) void {
    node_released += 1;
}
fn nodeTrav(p: ?*anyopaque, visit: ?kx.VisitFn) callconv(.c) void {
    node_visits += 1;
    const n: *Node = @ptrCast(@alignCast(p));
    var i: usize = 0;
    while (i < FANOUT) : (i += 1) visit.?(n.edges[i]);
}
var node_vt: kx.VTab = .{ .rel = nodeRel, .trav = nodeTrav, .relo = nodeRelo, .freemem = nodeFree, .cyclic = @ptrFromInt(1) };

fn nodeNew() *Node {
    const n: *Node = @ptrCast(@alignCast(gc.rt_alloc_trace(@sizeOf(Node)).?));
    n.* = .{ .hdr = 0, .vt = &node_vt, .edges = [_]?*Node{null} ** FANOUT };
    return n;
}
fn edge(from: *Node, slot: usize, to: *Node) void {
    from.edges[slot] = to;
    to.hdr += 1;
}

fn traversal(count: usize) void {
    if (!@hasDecl(gc, "debugWorkBytes")) return;
    node_freed = 0;
    node_released = 0;
    node_visits = 0;
    const nodes = std.heap.page_allocator.alloc(*Node, count) catch {
        fails += 1;
        return;
    };
    defer std.heap.page_allocator.free(nodes);
    var i: usize = 0;
    while (i < count) : (i += 1) nodes[i] = nodeNew();
    i = 0;
    while (i < count) : (i += 1) {
        var j: usize = 0;
        while (j < FANOUT) : (j += 1) edge(nodes[i], j, nodes[(i + 1) % count]);
    }
    nodes[count - 1].hdr += 1;
    gc.rt_cc_possible_root(nodes[0]);
    gc.rt_gc_collect();
    check(!@as(bool, node_freed != 0 or node_released != 0) and node_visits == 3 * count - 1, "live ring restored");
    i = 0;
    while (i < count) : (i += 1) {
        check(gc.debugRefCount(nodes[i]) == FANOUT + @as(u64, if (i == count - 1) 1 else 0), "ring count");
        check(gc.debugColor(nodes[i]) == 0 and !gc.debugIsBuffered(nodes[i]), "ring black");
    }
    nodes[count - 1].hdr -= 1;
    gc.rt_cc_possible_root(nodes[0]);
    gc.rt_gc_collect();
    check(node_freed == count and node_released == count and node_visits == 6 * count - 1, "garbage ring");
    const a = nodeNew();
    const b = nodeNew();
    const c = nodeNew();
    edge(a, 0, b);
    edge(a, 1, c);
    edge(c, 0, b);
    edge(b, 0, a);
    c.hdr += 1;
    gc.rt_cc_possible_root(a);
    gc.rt_gc_collect();
    check(node_freed == count and gc.debugRefCount(a) == 1 and gc.debugRefCount(b) == 2 and gc.debugRefCount(c) == 2, "sibling restore");
    c.hdr -= 1;
    gc.rt_cc_possible_root(c);
    gc.rt_gc_collect();
    check(node_freed == count + 3 and node_released == count + 3, "sibling cycle reclaimed");
    if (count == 4096) check(gc.debugWorkBytes() <= gc.debugInitialCap() * @sizeOf(?*anyopaque), "work cap bounded");
}

fn onePass() void {
    if (!std.mem.eql(u8, std.mem.span(gc.rt_gc_name()), "incremental")) return;
    if (@hasDecl(gc, "debugSetBudgetUs")) gc.debugSetBudgetUs(0);
    const RING = 20000;
    const ROOTS = 12000;
    const MAX_TRAV = 10 * RING;
    const Two = extern struct { hdr: u64, vt: *kx.VTab, a: ?*@This(), b: ?*@This() };
    var trav_calls: i64 = 0;
    var local_freed: i64 = 0;
    const Trav = struct {
        var calls: *i64 = undefined;
        var fr: *i64 = undefined;
        var vtab: kx.VTab = undefined;
        fn trav(p: ?*anyopaque, f: ?kx.VisitFn) callconv(.c) void {
            calls.* += 1;
            const o: *Two = @ptrCast(@alignCast(p));
            f.?(o.a);
            f.?(o.b);
        }
        fn relo(_: ?*anyopaque) callconv(.c) void {}
        fn freef(p: ?*anyopaque) callconv(.c) void {
            fr.* += 1;
            gc.rt_free_trace(p, @sizeOf(Two));
        }
    };
    Trav.calls = &trav_calls;
    Trav.fr = &local_freed;
    Trav.vtab = .{ .rel = null, .trav = Trav.trav, .relo = Trav.relo, .freemem = Trav.freef, .cyclic = @ptrFromInt(1) };
    const ring = std.heap.page_allocator.alloc(*Two, RING) catch {
        fails += 1;
        return;
    };
    defer std.heap.page_allocator.free(ring);
    var i: usize = 0;
    while (i < RING) : (i += 1) {
        const o: *Two = @ptrCast(@alignCast(gc.rt_alloc_trace(@sizeOf(Two)).?));
        o.* = .{ .hdr = 2, .vt = &Trav.vtab, .a = null, .b = null };
        ring[i] = o;
    }
    i = 0;
    while (i < RING) : (i += 1) ring[i].a = ring[(i + 1) % RING];
    i = 0;
    while (i < ROOTS) : (i += 1) {
        const gobj: *Two = @ptrCast(@alignCast(gc.rt_alloc_trace(@sizeOf(Two)).?));
        gobj.* = .{ .hdr = 2, .vt = &Trav.vtab, .a = gobj, .b = ring[0] };
        ring[0].hdr += 1;
        gobj.hdr -= 1;
        gc.rt_cc_possible_root(gobj);
    }
    gc.rt_gc_collect();
    check(local_freed == ROOTS and (ring[0].hdr & kx.CNT_MASK) == 2 and trav_calls <= MAX_TRAV, "one_pass");
}

pub fn main() u8 {
    const gname = std.mem.span(gc.rt_gc_name());
    std.debug.print("gc={s}\n", .{gname});
    acyclicAlloc();
    storageHooks();
    if (gc.caps.deferred) {
        apiDeferred();
    } else {
        acyclicChain();
        sharedSurvives();
        reachableCycle();
        noCollectWhileDraining();
        selfCycles();
        apiImmediate();
        apiTrialDeletion();
        if (std.mem.eql(u8, gname, "perceus") or std.mem.eql(u8, gname, "incremental")) {
            traversal(4096);
        }
        if (std.mem.eql(u8, gname, "incremental")) onePass();
    }
    var st: kx.Stats = undefined;
    gc.rt_gc_stats(&st);
    if (!gc.caps.cycles) check(st.collections == 0 and st.reclaimed == 0 and st.pause_ns_total == 0, "rc stats zero");
    check(st.pause_ns_total >= st.pause_ns_max and st.pause_ns_max >= 0, "pause totals");
    std.debug.print("collections={d} reclaimed={d} pause_max_us={d}\n", .{ st.collections, st.reclaimed, @divTrunc(st.pause_ns_max, 1000) });
    if (fails != 0) {
        std.debug.print("SUITE FAILED ({d})\n", .{fails});
        return 1;
    }
    std.debug.print("SUITE OK\n", .{});
    return 0;
}
