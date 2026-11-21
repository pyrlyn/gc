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

// Exercise the slab/large-block boundary with real deferred reclamation, including
// live payloads, unreachable cycles, and reuse across different size classes.
const Sized = extern struct {
    hdr: u64,
    vt: *kx.VTab,
    next: ?*Sized,
    bytes: usize,
    marker: u64,
};
var sized_freed: usize = 0;
fn sizedTrav(p: ?*anyopaque, visit: ?kx.VisitFn) callconv(.c) void {
    const s: *Sized = @ptrCast(@alignCast(p.?));
    visit.?(s.next);
}
fn sizedRelo(p: ?*anyopaque) callconv(.c) void {
    const s: *Sized = @ptrCast(@alignCast(p.?));
    const bytes: [*]u8 = @ptrCast(s);
    var intact = s.marker == 0xdeadbeef;
    for (bytes[@sizeOf(Sized)..s.bytes]) |b| intact = intact and b == 0xa5;
    check(intact, "sized object payload survives collection");
}
fn sizedFree(p: ?*anyopaque) callconv(.c) void {
    const s: *Sized = @ptrCast(@alignCast(p.?));
    const size = s.bytes;
    sized_freed += 1;
    gc.rt_free_trace(p, @intCast(size));
}
var sized_vt: kx.VTab = .{ .rel = null, .trav = sizedTrav, .relo = sizedRelo, .freemem = sizedFree, .cyclic = @ptrFromInt(1) };

fn deferredSizes() void {
    if (!gc.caps.deferred) return;
    const sizes = [_]usize{ 40, 248, 256, 257, 264, 511, 512, 513, 1024, 2048, 4095, 4096, 4097, 65536, 65537 };
    var ring: [128]*Sized = undefined;
    var expected: usize = 0;
    sized_freed = 0;
    for (0..3) |_| {
        for (sizes) |size| {
            for (&ring) |*slot| {
                const s: *Sized = @ptrCast(@alignCast(gc.rt_alloc_trace(@intCast(size)).?));
                s.* = .{ .hdr = 2, .vt = &sized_vt, .next = null, .bytes = size, .marker = 0xdeadbeef };
                const bytes: [*]u8 = @ptrCast(s);
                @memset(bytes[@sizeOf(Sized)..size], 0xa5);
                slot.* = s;
            }
            for (ring, 0..) |s, i| {
                @atomicStore(?*Sized, &s.next, ring[(i + 1) % ring.len], .release);
                gc.rt_gc_write_barrier(s);
            }
            // Leave one outside reference; the entire ring must remain live.
            for (ring[1..]) |s| gc.rt_gc_log_dec(s);
            gc.rt_gc_collect();
            check(sized_freed == expected, "sized reachable ring survives");
            for (ring) |s| sizedRelo(s);
            gc.rt_gc_log_dec(ring[0]);
            gc.rt_gc_collect();
            expected += ring.len;
            check(sized_freed == expected, "sized garbage ring reclaimed exactly once");
        }
    }
}

// MarkGray follows the fields as they were, Scan as they are. A store between the two (made here by
// the root's own `trav`, the first time it runs) leaves the objects behind the lost edge gray with a
// CRC; unless every object MarkGray reached is reset afterwards, the next detection does not trace
// through them and their cycle looks live for good.
var cut_root: ?*Obj = null;
var cut_armed: bool = false;
fn cutTrav(p: ?*anyopaque, f: ?kx.VisitFn) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(p));
    f.?(o.next);
    if (cut_armed and o == cut_root) {
        cut_armed = false;
        o.next = null;
    }
}
var cut_vt: kx.VTab = .{ .rel = objRel, .trav = cutTrav, .relo = objRelo, .freemem = objFree, .cyclic = @ptrFromInt(1) };

fn deferredLostEdge() void {
    if (comptime !gc.caps.deferred) return;
    gc.rt_gc_collect();
    freed = 0;
    const r = newObj(0);
    const b = newObj(1);
    const d = newObj(2);
    r.vt = &cut_vt;
    r.hdr = 2; // one reference stays with the test
    b.hdr = 2; // r and d
    r.next = b;
    b.next = d;
    d.next = b;
    cut_root = r;
    cut_armed = true;
    gc.rt_gc_log_dec(r); // r becomes a possible root
    gc.rt_gc_collect(); // MarkGray r -> b -> d, then r.next is cleared before Scan
    check(!cut_armed, "detection traced the root");
    gc.rt_gc_log_dec(b); // the log entries of that store
    gc.rt_gc_write_barrier(r);
    var i: u32 = 0;
    while (i < 3) : (i += 1) gc.rt_gc_collect();
    check(freed == 2, "cycle behind an edge lost between MarkGray and Scan");
    cut_root = null;
    gc.rt_gc_log_dec(r);
    gc.rt_gc_collect();
    check(freed == 3, "lost-edge root released");
}

// Returned objects are freed a few per allocation and a chunk per boundary. Freeing one releases
// its untraced child, whose `rel` logs: the log fills up and a boundary runs in the middle of the
// free, which frees returned objects itself. Every object must still be freed exactly once.
const PACED = 20000;
const Leaf = extern struct {
    hdr: u64,
    vt: *kx.VTab,
};
var paced_keep: ?*Obj = null;
var paced_seen: [PACED]u8 = @splat(0);
var paced_freed: usize = 0;
var paced_twice: usize = 0;
var leaf_released: usize = 0;
fn leafRel(p: ?*anyopaque) callconv(.c) void {
    leaf_released += 1;
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        gc.rt_gc_log_inc(paced_keep);
        gc.rt_gc_log_dec(paced_keep);
    }
    gc.rt_free(p, @sizeOf(Leaf));
}
var leaf_vt: kx.VTab = .{ .rel = leafRel, .trav = null, .relo = null, .freemem = null, .cyclic = null };
fn pacedFree(p: ?*anyopaque) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(p));
    const i: usize = @intCast(o.val);
    if (i >= PACED or paced_seen[i] != 0) paced_twice += 1 else paced_seen[i] = 1;
    paced_freed += 1;
    gc.rt_free_trace(p, @sizeOf(Obj));
}
var paced_vt: kx.VTab = .{ .rel = objRel, .trav = objTrav, .relo = objRelo, .freemem = pacedFree, .cyclic = @ptrFromInt(1) };

fn deferredPacedFree() void {
    if (comptime !gc.caps.deferred) return;
    gc.rt_gc_collect();
    gc.rt_gc_root_hint(null); // not an object: nothing to log
    gc.debugSetFreeBudgetUs(0); // a boundary frees one chunk, allocations the rest
    paced_keep = newObj(7);
    var i: usize = 0;
    while (i < PACED) : (i += 1) {
        const o = newObj(@intCast(i));
        o.vt = &paced_vt;
        const leaf: *Leaf = @ptrCast(@alignCast(gc.rt_alloc(@sizeOf(Leaf)).?));
        leaf.* = .{ .hdr = 1, .vt = &leaf_vt };
        o.next = @ptrCast(leaf);
        gc.rt_gc_log_dec(o);
    }
    // No collect: only boundaries and allocations free what the collector returns.
    var spins: usize = 0;
    while (paced_freed < PACED and spins < 20_000_000) : (spins += 1) gc.rt_gc_log_dec(newObj(0));
    check(paced_freed == PACED, "returned objects are freed without a collect");
    gc.rt_gc_collect();
    check(paced_freed == PACED and paced_twice == 0, "each returned object freed once");
    check(leaf_released == PACED, "each untraced child released once");
    check(gc.debugReturnsPending() == 0, "no returned object left after a collect");
    gc.debugSetFreeBudgetUs(-1);
    check(paced_keep.?.val == 7 and countOf(paced_keep.?) == 1, "object logged from a release survives");
    gc.rt_gc_log_dec(paced_keep);
    paced_keep = null;
    gc.rt_gc_collect();
}

// Rings are made, rewired, shrunk and dropped (garbage cycles and plain deaths) while the collector
// traces them, and the collector applies a queued log between any two objects it visits: counts,
// colors and edges change under every phase of a detection, and objects die on its stacks. Each
// object must be freed exactly once, and no ring may lose a node the program can still reach.
const STRESS_SLOTS = 512;
const STRESS_IDS = if (gc.caps.deferred) 1 << 21 else 0;
var stress_state: [STRESS_IDS]u8 = @splat(0); // 1 live, 2 freed
var stress_ids: usize = 0;
var stress_freed: usize = 0;
var stress_bad: usize = 0;
fn stressFree(p: ?*anyopaque) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(p));
    const id: usize = @intCast(o.val);
    if (id >= STRESS_IDS or stress_state[id] != 1) stress_bad += 1 else stress_state[id] = 2;
    stress_freed += 1;
    gc.rt_free_trace(p, @sizeOf(Obj));
}
var stress_vt: kx.VTab = .{ .rel = objRel, .trav = objTrav, .relo = objRelo, .freemem = stressFree, .cyclic = @ptrFromInt(1) };

fn stressNew() *Obj {
    const o = newObj(@intCast(stress_ids));
    o.vt = &stress_vt;
    stress_state[stress_ids] = 1;
    stress_ids += 1;
    return o;
}
/// `o.next = v`, as compiled code does it under deferred RC.
fn stressStore(o: *Obj, v: *Obj) void {
    gc.rt_gc_log_inc(v);
    const old = o.next;
    @atomicStore(?*Obj, &o.next, v, .release);
    gc.rt_gc_write_barrier(o);
    gc.rt_gc_log_dec(old);
}
/// A ring of `n`; the caller owns one reference to the node returned.
fn stressRing(n: usize) *Obj {
    const first = stressNew();
    var last = first;
    for (1..n) |_| {
        const x = stressNew();
        @atomicStore(?*Obj, &last.next, x, .release); // takes over the new object's reference
        gc.rt_gc_write_barrier(last);
        last = x;
    }
    gc.rt_gc_log_inc(first);
    @atomicStore(?*Obj, &last.next, first, .release);
    gc.rt_gc_write_barrier(last);
    return first;
}
fn stressCheck(head: *Obj, len: usize) void {
    var x = head;
    for (0..len) |_| {
        const id: usize = @intCast(x.val);
        if (id >= STRESS_IDS or stress_state[id] != 1) {
            stress_bad += 1;
            return;
        }
        x = x.next orelse {
            stress_bad += 1;
            return;
        };
    }
    if (x != head) stress_bad += 1;
}

fn deferredStress(poll_steps: u32, major: bool, iters: usize) void {
    if (comptime !@hasDecl(gc, "debugSetPollSteps")) return;
    gc.rt_gc_collect();
    gc.debugSetPollSteps(poll_steps);
    gc.debugForceMajor(major);
    const ids0 = stress_ids;
    const freed0 = stress_freed;
    var heads: [STRESS_SLOTS]*Obj = undefined;
    var lens: [STRESS_SLOTS]usize = undefined;
    for (&heads, &lens, 0..) |*h, *l, i| {
        l.* = 1 + i % 7;
        h.* = stressRing(l.*);
    }
    var rnd: u64 = @as(u64, 0x9e3779b97f4a7c15) +% poll_steps;
    for (0..iters) |it| {
        rnd = rnd *% 6364136223846793005 +% 1442695040888963407;
        const i: usize = @intCast((rnd >> 33) % STRESS_SLOTS);
        const head = heads[i];
        switch ((rnd >> 20) & 7) {
            0 => { // drop the ring: a garbage cycle
                lens[i] = 1 + @as(usize, @intCast((rnd >> 12) & 7));
                heads[i] = stressRing(lens[i]);
                gc.rt_gc_log_dec(head);
            },
            1, 2 => if (lens[i] > 1) { // unlink the node after the head: it dies, and releases its successor
                stressStore(head, head.next.?.next.?);
                lens[i] -= 1;
            },
            3, 4 => { // insert a node after the head
                const n = stressNew();
                const z = head.next.?;
                gc.rt_gc_log_inc(z);
                @atomicStore(?*Obj, &n.next, z, .release);
                gc.rt_gc_write_barrier(n);
                stressStore(head, n);
                gc.rt_gc_log_dec(n);
                lens[i] += 1;
            },
            5 => { // the slot moves on to the next node
                const nh = head.next.?;
                gc.rt_gc_log_inc(nh);
                heads[i] = nh;
                gc.rt_gc_log_dec(head);
            },
            6 => {
                gc.rt_gc_log_inc(head);
                gc.rt_gc_root_hint(head);
                gc.rt_gc_log_dec(head);
            },
            else => stressCheck(head, lens[i]),
        }
        if (it % 65536 == 65535) for (heads, lens) |h, l| stressCheck(h, l);
    }
    for (heads, lens) |h, l| stressCheck(h, l);
    gc.rt_gc_collect();
    for (heads, lens) |h, l| stressCheck(h, l);
    var live: usize = 0;
    for (lens) |l| live += l;
    check(stress_ids - ids0 - (stress_freed - freed0) == live, "stress: exactly the reachable rings are left");
    for (heads) |h| gc.rt_gc_log_dec(h);
    var k: u32 = 0;
    while (k < 4) : (k += 1) gc.rt_gc_collect();
    check(stress_freed - freed0 == stress_ids - ids0, "stress: every object freed");
    check(stress_bad == 0, "stress: no object freed twice or while reachable");
    gc.debugSetPollSteps(0);
    gc.debugForceMajor(false);
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
    n.* = .{ .hdr = 0, .vt = &node_vt, .edges = @splat(null) };
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
    // perceus: MarkGray, Scan and ScanBlack each traverse the ring (the root once less). incremental
    // counts without touching the counts, so nothing is restored: mark, then scan from the node
    // with the outside reference.
    const stepped = std.mem.eql(u8, std.mem.span(gc.rt_gc_name()), "incremental");
    const live_visits = if (stepped) 2 * count else 3 * count - 1;
    check(!@as(bool, node_freed != 0 or node_released != 0) and node_visits == live_visits, "live ring restored");
    i = 0;
    while (i < count) : (i += 1) {
        check(gc.debugRefCount(nodes[i]) == FANOUT + @as(u64, if (i == count - 1) 1 else 0), "ring count");
        check(gc.debugColor(nodes[i]) == 0 and !gc.debugIsBuffered(nodes[i]), "ring black");
    }
    nodes[count - 1].hdr -= 1;
    gc.rt_cc_possible_root(nodes[0]);
    gc.rt_gc_collect();
    // perceus: MarkGray, Scan, CollectWhite. incremental: mark, the batch's count, the release.
    check(node_freed == count and node_released == count and node_visits == live_visits + 3 * count, "garbage ring");
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

/// tests/incremental/slice_black.kt without newkotlinc: a root the collector found live leaves the
/// buffer, so its release later frees it exactly once (left in the buffer with the color cleared, a
/// step started mid-release would take it for dead and free it under the release). Run in steps of
/// one object.
fn sliceBlackRoot() void {
    if (!@hasDecl(gc, "debugSetStepUnits")) return;
    gc.rt_gc_collect();
    freed = 0;
    const x = newObj(3);
    const r = newObj(2);
    r.next = x;
    x.hdr += 1; // x: local + r
    const a = newObj(1);
    a.next = r; // r: a only
    a.hdr += 1; // a: live with count 2
    gc.rt_cc_possible_root(a);
    r.hdr += 1;
    objRel(r); // back to 1: r is the second buffered root
    gc.debugSetStepUnits(1);
    var steps: usize = 0;
    while (gc.rt_gc_idle_step(1_000_000) != 0) steps += 1;
    gc.debugSetStepUnits(0);
    check(steps > 4, "a cycle takes several one-object steps");
    check(!gc.debugIsBuffered(r) and gc.debugColor(r) == kx.BLACK and countOf(r) == 1 and freed == 0, "live root restored, unbuffered");
    check(gc.debugCycleBits(r) == 0 and gc.debugCycleBits(a) == 0 and gc.debugCycleBits(x) == 0, "cycle bits cleared");
    a.next = null;
    objRel(r);
    check(freed == 1, "live root freed once");
    objRel(a);
    objRel(a);
    objRel(x);
    gc.rt_gc_collect();
    check(freed == 3, "live root cleanup");
}

// A random graph of three-field objects is rewired while the collector runs in steps of a few
// objects: at every possible root (so also in the middle of a release, with objects up the stack at
// count zero and half released) and between operations. References are copied, dropped, and moved
// between fields and the root table without touching a count. A model of the root table says what
// is reachable: nothing reachable may be freed, every count must equal the references the model
// finds, and a full collection must leave exactly the reachable objects.
const Tri = extern struct { hdr: u64, vt: *kx.VTab, e: [3]?*Tri, id: i64 };
const TRI_IDS = if (@hasDecl(gc, "debugSetStepUnits")) 1 << 20 else 0;
const TRI_ROOTS = 96;
var tri_obj: [TRI_IDS]?*Tri = @splat(null); // null once freed
var tri_seen: [TRI_IDS]u32 = @splat(0);
var tri_refs: [TRI_IDS]u32 = @splat(0);
var tri_ids: usize = 0;
var tri_live: usize = 0;
var tri_bad: usize = 0;
var tri_pass: u32 = 0;
var tri_roots: [TRI_ROOTS]?*Tri = @splat(null);
var tri_queue: [TRI_IDS]u32 = undefined;

fn triFree(p: ?*anyopaque) callconv(.c) void {
    const o: *Tri = @ptrCast(@alignCast(p));
    const id: usize = @bitCast(@as(isize, @intCast(o.id)));
    if (id >= tri_ids or tri_obj[id] != o) tri_bad += 1 else {
        tri_obj[id] = null;
        tri_live -= 1;
    }
    // A collector that reads a freed object fails loudly.
    o.id = -1;
    o.e = @splat(@ptrFromInt(8));
    gc.rt_free_trace(p, @sizeOf(Tri));
}
fn triTrav(p: ?*anyopaque, f: ?kx.VisitFn) callconv(.c) void {
    const o: *Tri = @ptrCast(@alignCast(p));
    for (o.e) |c| f.?(c);
}
fn triRelo(_: ?*anyopaque) callconv(.c) void {}
fn triRel(p: ?*anyopaque) callconv(.c) void {
    const o: *Tri = @ptrCast(@alignCast(p orelse return));
    const c1 = o.hdr -% 1;
    if (c1 & kx.CNT_MASK != 0) {
        o.hdr = c1 | (@as(u64, 3) << kx.COLOR_SHIFT);
        if (c1 & kx.BUF_BIT == 0) gc.rt_cc_possible_root(p);
        return;
    }
    o.hdr = c1;
    for (o.e) |c| triRel(c);
    if (o.hdr & kx.BUF_BIT != 0) {
        o.hdr &= ~(@as(u64, 3) << kx.COLOR_SHIFT);
        return;
    }
    triFree(p);
}
var tri_vt: kx.VTab = .{ .rel = triRel, .trav = triTrav, .relo = triRelo, .freemem = triFree, .cyclic = @ptrFromInt(1) };

fn triNew() ?*Tri {
    if (tri_ids == TRI_IDS) return null;
    const o: *Tri = @ptrCast(@alignCast(gc.rt_alloc_trace(@sizeOf(Tri)).?));
    o.* = .{ .hdr = 1, .vt = &tri_vt, .e = @splat(null), .id = @intCast(tri_ids) };
    tri_obj[tri_ids] = o;
    tri_ids += 1;
    tri_live += 1;
    return o;
}
/// Walks what the root table reaches; returns how many objects, 0 after finding a freed one.
/// `exact`: every count equals the references found, and no object is buffered or held.
fn triCheck(exact: bool) usize {
    tri_pass += 1;
    var n: usize = 0;
    var head: usize = 0;
    const visit = struct {
        fn f(p: ?*Tri, tail: *usize) bool {
            const o = p orelse return true;
            const id: usize = @bitCast(@as(isize, @intCast(o.id)));
            if (id >= tri_ids or tri_obj[id] != o) return false;
            if (tri_seen[id] != tri_pass) {
                tri_seen[id] = tri_pass;
                tri_refs[id] = 0;
                tri_queue[tail.*] = @intCast(id);
                tail.* += 1;
            }
            tri_refs[id] += 1;
            return true;
        }
    }.f;
    for (tri_roots) |r| if (!visit(r, &n)) return 0;
    while (head < n) : (head += 1) {
        const o = tri_obj[tri_queue[head]].?;
        for (o.e) |c| if (!visit(c, &n)) return 0;
    }
    if (exact) for (tri_queue[0..n]) |id| {
        const o = tri_obj[id].?;
        if (countOf(@ptrCast(o)) != tri_refs[id] or gc.debugIsBuffered(o) or gc.debugCycleBits(o) != 0) return 0;
    };
    return n + 1;
}

fn steppedStress(units: usize, live_max: usize, iters: usize) void {
    if (comptime !@hasDecl(gc, "debugSetStepUnits")) return;
    gc.rt_gc_collect();
    gc.debugSetStepUnits(units);
    const bad0 = tri_bad;
    var rnd: u64 = @as(u64, 0x9e3779b97f4a7c15) *% (units + 1);
    for (0..iters) |it| {
        rnd = rnd *% 6364136223846793005 +% 1442695040888963407;
        const i: usize = @intCast((rnd >> 33) % TRI_ROOTS);
        const j: usize = @intCast((rnd >> 41) % TRI_ROOTS);
        const k: usize = @intCast((rnd >> 50) % 3);
        const l: usize = @intCast((rnd >> 53) % 3);
        const a = tri_roots[i];
        const b = tri_roots[j];
        switch ((rnd >> 16) % 16) {
            0, 1 => if (tri_live < live_max) { // a new object in the slot
                tri_roots[i] = triNew();
                triRel(a);
            },
            2, 3 => if (a) |x| { // a.e[k] = b
                if (b) |y| y.hdr += 1;
                const old = x.e[k];
                x.e[k] = b;
                triRel(old);
            },
            4 => if (a) |x| { // a.e[k] = b and b.e[l] = a: a cycle (a loop when the slots share an object)
                if (b) |y| {
                    y.hdr += 1;
                    const old = x.e[k];
                    x.e[k] = y;
                    triRel(old);
                    x.hdr += 1;
                    const old2 = y.e[l];
                    y.e[l] = x;
                    triRel(old2);
                }
            },
            5, 6 => if (a) |x| { // the slot moves on to a field of its object
                const nx = x.e[k];
                if (nx) |y| y.hdr += 1;
                tri_roots[i] = nx;
                triRel(x);
            },
            7 => { // drop the slot
                tri_roots[i] = null;
                triRel(a);
            },
            8, 9 => if (a) |x| { // a field's reference moves out to an empty slot: no count changes
                if (b == null) {
                    tri_roots[j] = x.e[k];
                    x.e[k] = null;
                }
            },
            10, 11 => if (a) |x| { // a slot's reference moves into an empty field of another object
                if (b) |y| if (x != y and y.e[l] == null) {
                    y.e[l] = x;
                    tri_roots[i] = null;
                };
            },
            12 => if (a) |x| { // a field's reference moves to an empty field of another object
                if (b) |y| if (y.e[l] == null) {
                    y.e[l] = x.e[k];
                    x.e[k] = null;
                };
            },
            13 => if (a) |x| { // a.e[k] = a.e[l].e[k]
                const v: ?*Tri = if (x.e[l]) |y| y.e[k] else null;
                if (v) |y| y.hdr += 1;
                const old = x.e[k];
                x.e[k] = v;
                triRel(old);
            },
            14 => _ = gc.rt_gc_idle_step(1_000_000),
            else => if (a) |x| {
                x.hdr += 1;
                gc.rt_gc_root_hint(x);
                triRel(x);
            },
        }
        if ((rnd >> 8) & 3 == 0) _ = gc.rt_gc_idle_step(1_000_000);
        if (it % 512 == 511 and triCheck(false) == 0) {
            tri_bad += 1;
            break;
        }
        if (it % 8192 == 8191) {
            gc.rt_gc_collect();
            const n = triCheck(true);
            if (n == 0 or n - 1 != tri_live) {
                tri_bad += 1;
                break;
            }
        }
    }
    gc.rt_gc_collect();
    const n = triCheck(true);
    check(n != 0 and n - 1 == tri_live, "stepped stress: exactly the reachable objects are left, counts exact");
    for (&tri_roots) |*r| {
        const o = r.*;
        r.* = null;
        triRel(o);
    }
    gc.rt_gc_collect();
    check(tri_live == 0, "stepped stress: every object freed");
    check(tri_bad == bad0, "stepped stress: no object freed twice or while reachable");
    check(gc.debugHeldDead() == 0, "stepped stress: no freed memory kept after the last cycle");
    gc.debugSetStepUnits(0);
}

/// 200-byte blocks, a size class no other test uses: the pool has to grow for them.
const Filler = extern struct { zero: u64, next: ?*Filler, pad: [184]u8 };

/// Allocates until the collector has brought `tri_live` down to `target`, 64 MiB at most.
fn fillUntil(target: usize, head: *?*Filler) void {
    var n: usize = 0;
    while (tri_live != target and n < (64 << 20) / @sizeOf(Filler)) : (n += 1) {
        const f: *Filler = @ptrCast(@alignCast(gc.rt_alloc_trace(@sizeOf(Filler)).?));
        f.zero = 0;
        f.next = head.*;
        head.* = f;
    }
}

/// incremental: an object a cycle found live is old. Minor cycles stop at old objects and leave
/// their roots, and the roots that reached one, to major cycles; a major cycle is started by the
/// roots deferred or by the heap's growth, which also frees the deferred roots that died.
fn generations() void {
    if (comptime !@hasDecl(gc, "debugDeferredLen")) return;
    gc.rt_gc_collect();
    const live0 = tri_live;
    const bad0 = tri_bad;
    var fill: ?*Filler = null;
    // o1 <-> o2, o1 held from outside as well.
    const o1 = triNew().?;
    const o2 = triNew().?;
    o1.e[0] = o2;
    o2.e[0] = o1;
    o1.hdr += 2;
    triRel(o1);
    gc.rt_gc_collect();
    check(tri_live == live0 + 2 and !gc.debugIsBuffered(o1) and gc.debugDeferredLen() == 0, "live cycle left unbuffered");
    // y1 <-> y2 is garbage and refers to o1.
    const y1 = triNew().?;
    const y2 = triNew().?;
    y1.e[0] = y2;
    y2.e[0] = y1;
    y1.e[1] = o1;
    o1.hdr += 1;
    y1.hdr += 1;
    triRel(y1);
    _ = gc.rt_gc_idle_step(1_000_000);
    check(tri_live == live0 + 2 and gc.debugDeferredLen() == 0, "a minor cycle frees young garbage that refers to an old object");
    check(gc.debugIsBuffered(o1) and countOf(@ptrCast(o1)) == 2, "its reference to the old object is released");
    check(gc.rt_gc_idle_step(1_000_000) == 1 and gc.debugDeferredLen() == 1 and gc.debugIsBuffered(o1), "an old root waits for a major cycle");
    // The last reference from outside: o1 is buffered, so the collector is not told. Only the
    // heap's growth makes the major cycle due.
    triRel(o1);
    check(tri_live == live0 + 2, "old garbage waits");
    fillUntil(live0, &fill);
    check(tri_live == live0 and gc.debugDeferredLen() == 0, "the heap's growth starts a major cycle");
    // A live young root that refers to an old object is deferred: it may be garbage through it.
    const o = triNew().?;
    o.hdr += 1;
    triRel(o);
    gc.rt_gc_collect();
    const y = triNew().?;
    y.e[0] = o;
    o.hdr += 1;
    y.hdr += 1;
    triRel(y);
    check(gc.rt_gc_idle_step(1_000_000) == 1 and gc.debugIsBuffered(y) and gc.debugDeferredLen() == 1, "a root that reached an old object is deferred");
    check(gc.debugColor(y) == kx.PURPLE and gc.debugCycleBits(y) == 0 and countOf(@ptrCast(y)) == 1, "deferred root colored as a buffered one");
    o.e[0] = y; // takes the reference held here: y <-> o
    triRel(o);
    check(tri_live == live0 + 2, "garbage through an old object waits");
    while (gc.rt_gc_idle_step(1_000_000) != 0) {}
    check(tri_live == live0 and gc.debugDeferredLen() == 0, "a major cycle collects garbage through an old object");
    // An old root that dies while deferred keeps its memory until the heap grows.
    const z = triNew().?;
    z.hdr += 2;
    triRel(z);
    gc.rt_gc_collect();
    triRel(z);
    check(gc.rt_gc_idle_step(1_000_000) == 1 and gc.debugDeferredLen() == 1, "old root deferred");
    triRel(z);
    check(tri_live == live0 + 1, "a root that died while deferred is the collector's");
    fillUntil(live0, &fill);
    check(tri_live == live0 and gc.debugDeferredLen() == 0, "the heap's growth frees dead deferred roots");
    check(tri_bad == bad0, "generations: nothing freed twice");
    while (fill) |f| {
        fill = f.next;
        gc.rt_free_trace(f, @sizeOf(Filler));
    }
    gc.rt_gc_collect();
}

/// regions.zig pool: a page whose last block is freed goes to a stock that other size classes take
/// pages from, never a page that still holds a live block; the free blocks of a page that does
/// serve its own class again.
fn poolCompaction() void {
    if (!@hasDecl(gc, "debugPoolPages")) return;
    const N = 20000; // 56-byte blocks: about 70 pages of class 7, which no other test uses
    const PIN = 1024; // every PIN-th block stays live: 20 pinned pages, about 50 emptied ones
    const PINNED = (N + PIN - 1) / PIN;
    const HDR = 32; // page header
    const blocks = std.heap.page_allocator.alloc([*]u64, N) catch {
        fails += 1;
        return;
    };
    defer std.heap.page_allocator.free(blocks);
    for (blocks, 0..) |*b, i| {
        b.* = @ptrCast(@alignCast(gc.rt_alloc_trace(56).?));
        @memset(b.*[0..7], i);
    }
    for (blocks, 0..) |b, i| if (i % PIN != 0) gc.rt_free_trace(b, 56);
    const pages = gc.debugPoolPages();
    // 40 pages of 120-byte blocks (class 15, also unused elsewhere) come from the emptied ones.
    const other = std.heap.page_allocator.alloc([*]u8, 40 * (((16 << 10) - HDR) / 120)) catch {
        fails += 1;
        return;
    };
    defer std.heap.page_allocator.free(other);
    for (other) |*o| {
        o.* = @ptrCast(gc.rt_alloc_trace(120).?);
        @memset(o.*[0..120], 0xee);
    }
    // A walk of the free lists finds the emptied pages once enough was handed out since the last one
    // began, and sorts them 4096 blocks per page taken (regions.zig WALK_GAP, WALK_STEP): a few pages
    // of 120-byte blocks may come from the system first.
    check(gc.debugPoolPages() <= pages + 8, "another size class reuses emptied pages");
    const after_other = gc.debugPoolPages();
    // Every free block of the pinned pages: more than the 8 emptied pages left can hold.
    const again = std.heap.page_allocator.alloc([*]u64, PINNED * (((16 << 10) - HDR) / 56 - 1)) catch {
        fails += 1;
        return;
    };
    defer std.heap.page_allocator.free(again);
    for (again, 0..) |*b, i| {
        b.* = @ptrCast(@alignCast(gc.rt_alloc_trace(56).?));
        @memset(b.*[0..7], ~i);
    }
    check(gc.debugPoolPages() == after_other, "a size class reuses the free blocks of its pinned pages");
    var intact = true;
    var i: usize = 0;
    while (i < N) : (i += PIN) {
        for (blocks[i][0..7]) |w| intact = intact and w == i;
    }
    for (again, 0..) |b, k| {
        for (b[0..7]) |w| intact = intact and w == ~k;
    }
    check(intact, "pinned pages keep their live blocks");
    for (again) |b| gc.rt_free_trace(b, 56);
    for (other) |o| gc.rt_free_trace(o, 120);
    i = 0;
    while (i < N) : (i += PIN) gc.rt_free_trace(blocks[i], 56);
}

pub fn main() u8 {
    const gname = std.mem.span(gc.rt_gc_name());
    std.debug.print("gc={s}\n", .{gname});
    acyclicAlloc();
    storageHooks();
    poolCompaction();
    if (gc.caps.deferred) {
        apiDeferred();
        deferredSizes();
        deferredLostEdge();
        deferredPacedFree();
        deferredStress(1, false, 150_000);
        deferredStress(2, true, 150_000);
        deferredStress(3, false, 150_000);
        deferredStress(0, false, 400_000);
        deferredStress(0, true, 400_000);
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
        if (std.mem.eql(u8, gname, "incremental")) {
            onePass();
            sliceBlackRoot();
            generations();
            steppedStress(1, 200, 200_000);
            steppedStress(3, 400, 200_000);
            steppedStress(17, 3000, 300_000);
            steppedStress(1000, 3000, 300_000);
        }
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
