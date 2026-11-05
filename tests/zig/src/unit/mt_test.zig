//! New multithreaded test of a deferred-RC collector (epoch), run by src/runner.zig ("gc-mt" lines).
//! Arguments: <gc name>.
//!
//! The kxgc.h contract allows one mutator at a time (epoch: "the mutator is single-threaded"), but the
//! collector itself is concurrent: a background collector thread applies the logs and runs trial deletion,
//! KX_GC_THREADS - 1 helpers run MarkGray/Scan in parallel, and the mutator hands logs over / waits for full
//! collections through a mutex and condition variables. This test stresses exactly that:
//!   * THREADS OS threads take turns as the mutator (a pthread mutex hands the role over, so the GC sees
//!     one mutator at a time, as from a program whose threads are serialized), and objects created on one
//!     thread are retained, rewired and released on others;
//!   * every turn allocates, retains (rt_gc_log_inc), releases (rt_gc_log_dec), rewires fields with
//!     rt_gc_write_barrier (arbitrary cycles through a shared pool) and builds garbage rings;
//!   * rt_gc_collect (the stop-the-world hand-off) runs mid-workload, from different threads, while the
//!     collector is busy with queued logs;
//!   * the runner sets small logs (many hand-offs) and KX_GC_THREADS=4 (parallel detection).
//! Checks: no object is freed twice or while reachable (a magic word is verified on every visit and on
//! free), every allocated object is freed by the final collections, stats are consistent. The runner also
//! builds it with -fsanitize=thread, which reports races and mutex misuse in the collector (e.g. a missing
//! pthread_mutex_lock before a pthread_cond_wait).
const std = @import("std");
const kx = @import("kx.zig");
const c = kx.c;
const pt = @cImport(@cInclude("pthread.h"));

extern fn usleep(us: c_uint) c_int;

const MAGIC: u64 = 0x6b78_6763_6d74_0001;
/// `aux` is a reference the collector does not trace (like ArrayList storage): released by relo through the
/// log, so a log can fill up while the mutator frees returned objects (the nested boundary hand-off).
/// `side` is a second traced reference, set only in the quiet phase (a garbage ring pointing into the pool).
const Obj = extern struct { hdr: u64, vt: *c.KxVTab, next: ?*Obj, magic: u64, val: i64, aux: ?*Obj, side: ?*Obj };

var allocated: i64 = 0;
var freed: i64 = 0;
var corrupt: i64 = 0;

fn objFree(p: ?*anyopaque) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(p));
    if (o.magic != MAGIC) corrupt += 1; // freed twice, or memory reused under a live object
    o.magic = 0;
    _ = @atomicRmw(i64, &freed, .Add, 1, .monotonic);
    c.rt_free_trace(p, @sizeOf(Obj));
}
fn objTrav(p: ?*anyopaque, f: c.kx_visit_fn) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(p));
    f.?(@ptrCast(mt_load(@ptrCast(&o.next))));
    f.?(@ptrCast(mt_load(@ptrCast(&o.side))));
}
fn objRelo(p: ?*anyopaque) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(p));
    if (o.magic != MAGIC) corrupt += 1;
    if (o.aux) |a| {
        o.aux = null;
        c.rt_gc_log_dec(a);
    }
}
fn objRel(_: ?*anyopaque) callconv(.c) void {} // deferred RC: generated code never releases directly
// src/unit/mt_shim.c (instrumented with the collector under TSan)
extern fn mt_init(o: *u64, vt: *c.KxVTab, magic: u64, val: i64) void;
extern fn mt_store(field: *?*anyopaque, v: ?*anyopaque) void;
extern fn mt_load(field: *?*anyopaque) ?*anyopaque;
var vt: c.KxVTab = .{ .rel = objRel, .trav = objTrav, .relo = objRelo, .freemem = objFree, .cyclic = @ptrFromInt(1) };

fn newObj(v: i64) *Obj {
    const o: *Obj = @ptrCast(@alignCast(c.rt_alloc_trace(@sizeOf(Obj))));
    mt_init(@ptrCast(o), &vt, MAGIC, v);
    allocated += 1;
    return o;
}
/// A reference store into a traced field: release store, then the write barrier; the old value's
/// reference is dropped through the log.
fn store(o: *Obj, v: ?*Obj) void {
    const old = o.next;
    mt_store(@ptrCast(&o.next), v);
    c.rt_gc_write_barrier(o);
    if (old) |x| c.rt_gc_log_dec(x);
}
fn alive(o: *Obj) bool {
    // Walk a bounded prefix of the chain: everything reachable from a held reference must be intact.
    var x: ?*Obj = o;
    var n: usize = 0;
    while (x) |y| : (n += 1) {
        if (n == 16) break;
        if (y.magic != MAGIC) return false;
        x = y.next;
    }
    return true;
}

const THREADS = 4;
const TURNS = 180;
const OPS = 400;
const SLOTS = 128;

var role: pt.pthread_mutex_t = undefined; // the mutator role
var pool: [SLOTS]?*Obj = [_]?*Obj{null} ** SLOTS; // one reference per non-null slot
var collects: i64 = 0;
var bad_reads: i64 = 0;

const Rng = struct {
    s: u64,
    fn next(r: *Rng) u64 {
        r.s ^= r.s << 13;
        r.s ^= r.s >> 7;
        r.s ^= r.s << 17;
        return r.s;
    }
    fn below(r: *Rng, n: u64) usize {
        return @intCast(r.next() % n);
    }
};

fn put(slot: usize, o: *Obj) void {
    if (pool[slot]) |old| c.rt_gc_log_dec(old);
    pool[slot] = o;
}

/// `quiet` turns never call rt_gc_collect: the background collector alone has to start its majors (the
/// incremental one, or the stop-the-world one under KX_GC_INC_MAJOR=0) from the deferred roots of a large
/// live pool, and the idle gap after the turn lets it advance an incremental major with an empty queue.
fn step(r: *Rng, tid: i64, quiet: bool) void {
    if (quiet) return quietStep(r, tid);
    switch (r.below(100)) {
        // a ring of 1..9 built as generated code does: every new object starts with its local reference,
        // a field store retains its target, and the locals are released at the end of the scope (those
        // decrements to non-zero make the members candidate roots). Some rings are kept from the pool (an
        // outside reference, released later by some other thread); the rest are garbage cycles at once.
        0...39 => {
            var ring: [9]*Obj = undefined;
            const n = 1 + r.below(9);
            for (0..n) |i| {
                ring[i] = newObj(tid);
                if (r.below(2) == 0) ring[i].aux = newObj(-1); // a leaf: its creation reference moves into aux
            }
            for (0..n) |i| {
                c.rt_gc_log_inc(ring[(i + 1) % n]);
                store(ring[i], ring[(i + 1) % n]);
            }
            if (r.below(3) == 0) {
                c.rt_gc_log_inc(ring[0]);
                put(r.below(SLOTS), ring[0]);
            }
            for (ring[0..n]) |o| c.rt_gc_log_dec(o);
        },
        // rewire: a.next = b between pool objects (cycles across objects of different threads, self-loops)
        40...64 => {
            const a = pool[r.below(SLOTS)] orelse return;
            const b = pool[r.below(SLOTS)];
            if (b) |x| c.rt_gc_log_inc(x);
            store(a, b);
        },
        // copy a reference between slots (sharing), or drop one
        65...79 => {
            const from = pool[r.below(SLOTS)] orelse return;
            c.rt_gc_log_inc(from);
            put(r.below(SLOTS), from);
        },
        80...91 => {
            const s = r.below(SLOTS);
            if (pool[s]) |o| {
                pool[s] = null;
                c.rt_gc_log_dec(o);
            }
        },
        // retain / release churn on a held object, and read what it reaches
        92...98 => {
            const o = pool[r.below(SLOTS)] orelse return;
            const k = 1 + r.below(4);
            for (0..k) |_| c.rt_gc_log_inc(o);
            if (!alive(o)) bad_reads += 1;
            for (0..k) |_| c.rt_gc_log_dec(o);
        },
        // full collection from whichever thread holds the mutator role
        else => {
            c.rt_gc_collect();
            collects += 1;
        },
    }
}

/// Quiet phase: the pool is left alone (no rewires, so its objects stay in the old generation) and only
/// referenced: garbage rings hanging off a pool object and retain/release churn on pool objects. Minor
/// detections from those roots hit old objects and defer them, which is what triggers background majors.
fn quietStep(r: *Rng, tid: i64) void {
    const target = pool[r.below(SLOTS)] orelse return;
    if (r.below(2) == 0) {
        c.rt_gc_log_inc(target);
        c.rt_gc_log_dec(target);
        return;
    }
    var ring: [4]*Obj = undefined;
    const n = 1 + r.below(4);
    for (0..n) |i| ring[i] = newObj(tid);
    for (0..n) |i| {
        c.rt_gc_log_inc(ring[(i + 1) % n]);
        store(ring[i], ring[(i + 1) % n]);
    }
    c.rt_gc_log_inc(target);
    mt_store(@ptrCast(&ring[0].side), target); // a garbage cycle that reaches the old generation
    c.rt_gc_write_barrier(ring[0]);
    for (ring[0..n]) |o| c.rt_gc_log_dec(o);
}

fn worker(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const tid: i64 = @intCast(@intFromPtr(arg));
    var r: Rng = .{ .s = 0x9e37_79b9_7f4a_7c15 ^ @as(u64, @intCast(tid + 1)) *% 0x2545_f491_4f6c_dd1d };
    for (0..TURNS) |turn| {
        _ = pt.pthread_mutex_lock(&role);
        const quiet = turn >= TURNS / 3;
        for (0..OPS) |_| step(&r, tid, quiet);
        _ = pt.pthread_mutex_unlock(&role);
        if (quiet) _ = usleep(300) else _ = pt.sched_yield();
    }
    return null;
}

export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    const want = if (argc > 1) std.mem.span(argv[1]) else "";
    kx.check(std.mem.eql(u8, std.mem.span(c.rt_gc_name()), want), @src(), "rt_gc_name() matches the selected collector");
    _ = pt.pthread_mutex_init(&role, null);
    var ts: [THREADS]pt.pthread_t = undefined;
    for (0..THREADS) |i| kx.require(pt.pthread_create(&ts[i], null, worker, @ptrFromInt(i)) == 0, @src(), "pthread_create");
    for (0..THREADS) |i| _ = pt.pthread_join(ts[i], null);
    // Drop every pool reference, then collect until nothing is left.
    for (&pool) |*s| if (s.*) |o| {
        s.* = null;
        c.rt_gc_log_dec(o);
    };
    for (0..3) |_| c.rt_gc_collect();
    kx.check(corrupt == 0, @src(), "no object freed twice or visited after free");
    kx.check(bad_reads == 0, @src(), "everything reachable from a held reference is intact");
    kx.check(freed == allocated, @src(), "every allocated object is freed by the final collections");
    var st: c.KxGcStats = undefined;
    c.rt_gc_stats(&st);
    kx.check(st.collections > 0 and st.reclaimed > 0 and st.reclaimed <= allocated, @src(), "stats: collections and 0 < reclaimed <= allocated");
    kx.check(st.pause_ns_total >= st.pause_ns_max and st.pause_ns_max >= 0, @src(), "pause_ns_total >= pause_ns_max >= 0");
    _ = c.printf("gc=%s threads=%d allocated=%lld freed=%lld collects=%lld collections=%lld\n", c.rt_gc_name(), @as(c_int, THREADS), @as(c_longlong, allocated), @as(c_longlong, freed), @as(c_longlong, collects), @as(c_longlong, st.collections));
    if (kx.fails != 0) {
        _ = c.printf("MT FAILED (%d)\n", kx.fails);
        return 1;
    }
    _ = c.printf("MT OK\n");
    return 0;
}
