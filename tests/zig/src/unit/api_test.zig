//! New (non-ported) unit tests of the kxgc.h C interface, run for every collector by src/runner.zig
//! ("gc-api" lines). Arguments: <gc name> [cycles] [precise] [deferred].
//! Areas: acyclic allocation, runtime storage hooks, immediate RC (inc/dec, chains, sharing), trial
//! deletion (garbage rings, rings kept alive by an outside reference, counts restored), statistics, and for
//! deferred-RC collectors (epoch) the log protocol: rt_gc_log_inc / rt_gc_log_dec / rt_gc_write_barrier.
const std = @import("std");
const kx = @import("kx.zig");
const c = kx.c;

const Obj = extern struct { hdr: u64, vt: *c.KxVTab, next: ?*Obj, val: i64 };
var freed: i64 = 0;
var relo_calls: i64 = 0;
fn objFree(p: ?*anyopaque) callconv(.c) void {
    freed += 1;
    c.rt_free_trace(p, @sizeOf(Obj));
}
fn objTrav(p: ?*anyopaque, f: c.kx_visit_fn) callconv(.c) void {
    f.?(@as(*Obj, @ptrCast(@alignCast(p))).next);
}
fn objRelo(_: ?*anyopaque) callconv(.c) void {
    relo_calls += 1;
}
var vt: c.KxVTab = .{ .rel = objRel, .trav = objTrav, .relo = objRelo, .freemem = objFree, .cyclic = @ptrFromInt(1) };
/// Generated-code release path for a cyclic class (immediate RC), as in gc_unit.
fn objRel(p: ?*anyopaque) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(p orelse return));
    const c1 = o.hdr -% 1;
    if (c1 & kx.CNT_MASK != 0) {
        if (c1 & kx.BUF_BIT != 0) {
            o.hdr = c1 | (@as(u64, 3) << kx.COLOR_SHIFT);
            return;
        }
        o.hdr = c1;
        c.rt_cc_possible_root(p);
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
fn newObj(v: i64) *Obj {
    const o: *Obj = @ptrCast(@alignCast(c.rt_alloc_trace(@sizeOf(Obj))));
    o.* = .{ .hdr = 1, .vt = &vt, .next = null, .val = v };
    return o;
}
fn count(o: *Obj) u64 {
    return o.hdr & kx.CNT_MASK;
}

const check = kx.check;

fn acyclicAlloc() void {
    // Interleaved sizes, every block filled with a pattern and verified before it is freed (LIFO and FIFO).
    const sizes = [_]i64{ 16, 24, 48, 64, 128, 1000, 4096, 70000 };
    var blocks: [64][*]u8 = undefined;
    for (0..4) |round| {
        for (0..64) |i| {
            const sz = sizes[(i + round) % sizes.len];
            const b: [*]u8 = @ptrCast(c.rt_alloc(sz));
            @memset(b[0..@intCast(sz)], @truncate(i));
            blocks[i] = b;
        }
        var ok = true;
        for (0..64) |i| {
            const sz: usize = @intCast(sizes[(i + round) % sizes.len]);
            for (blocks[i][0..sz]) |x| ok = ok and x == @as(u8, @truncate(i));
        }
        check(ok, @src(), "acyclic blocks keep their contents until freed");
        for (0..64) |k| {
            const i = if (round % 2 == 0) 63 - k else k;
            c.rt_free(blocks[i], sizes[(i + round) % sizes.len]);
        }
    }
    // Traced allocations are distinct and writable.
    const a = newObj(1);
    const b = newObj(2);
    check(a != b and a.val == 1 and b.val == 2, @src(), "two traced objects are distinct");
    if (!caps.deferred) {
        objRel(a);
        objRel(b);
    } else {
        c.rt_gc_log_dec(a);
        c.rt_gc_log_dec(b);
    }
}

fn storageHooks() void {
    const big: [*]u8 = @ptrCast(c.rt_gc_mem_calloc(1 << 20));
    var zero = true;
    for (big[0 .. 1 << 20]) |x| zero = zero and x == 0;
    check(zero, @src(), "rt_gc_mem_calloc(1 MiB) is zeroed");
    for (0..1024) |i| big[i] = @truncate(i);
    const grown: [*]u8 = @ptrCast(c.rt_gc_mem_realloc(big, 4 << 20));
    var kept = true;
    for (0..1024) |i| kept = kept and grown[i] == @as(u8, @truncate(i));
    check(kept, @src(), "rt_gc_mem_realloc keeps the prefix when growing");
    const shrunk: [*]u8 = @ptrCast(c.rt_gc_mem_realloc(grown, 512));
    kept = true;
    for (0..512) |i| kept = kept and shrunk[i] == @as(u8, @truncate(i));
    check(kept, @src(), "rt_gc_mem_realloc keeps the prefix when shrinking");
    c.rt_gc_mem_free(shrunk);
    const m: ?*anyopaque = c.rt_gc_mem_alloc(32);
    check(m != null, @src(), "rt_gc_mem_alloc(32) != NULL");
    c.rt_gc_mem_free(m);
}

fn immediateRc() void {
    // A chain of 1000 is freed by one release of its head, without the collector.
    freed = 0;
    relo_calls = 0;
    var head: ?*Obj = null;
    for (0..1000) |i| {
        const o = newObj(@intCast(i));
        o.next = head;
        head = o;
    }
    var before: c.KxGcStats = undefined;
    c.rt_gc_stats(&before);
    objRel(head);
    check(freed == 1000 and relo_calls == 1000, @src(), "releasing a 1000-chain frees all of it");
    // Increment / decrement pairs leave the count where it was; the object stays alive.
    freed = 0;
    const s = newObj(7);
    for (0..10) |_| s.hdr += 1;
    for (0..10) |_| objRel(s);
    check(count(s) == 1 and s.val == 7 and freed == 0, @src(), "balanced inc/dec keeps the object");
    objRel(s);
    c.rt_gc_collect();
    check(freed == 1, @src(), "last release frees it (possibly at the next collection)");
    // A shared tail outlives one of its two owners.
    freed = 0;
    const tail = newObj(3);
    const o1 = newObj(1);
    const o2 = newObj(2);
    o1.next = tail;
    o2.next = tail;
    tail.hdr += 1;
    tail.hdr -= 1; // the creation reference moved into o1; o2's reference:
    tail.hdr += 1;
    objRel(o1);
    check(count(tail) == 1 and tail.val == 3, @src(), "shared tail survives its first owner");
    objRel(o2);
    c.rt_gc_collect();
    check(freed == 3, @src(), "both owners and the tail are freed");
}

fn trialDeletion() void {
    // A garbage ring of 100 is reclaimed.
    freed = 0;
    const R = 100;
    var ring: [R]*Obj = undefined;
    for (0..R) |i| ring[i] = newObj(@intCast(i));
    for (0..R) |i| {
        ring[i].next = ring[(i + 1) % R];
        ring[(i + 1) % R].hdr += 1;
    }
    for (0..R) |i| objRel(ring[i]); // drop the creation references
    for (0..3) |_| c.rt_gc_collect();
    if (caps.precise) check(freed == R, @src(), "a garbage ring of 100 is reclaimed");
    // A ring kept alive from outside survives, with every count restored exactly.
    freed = 0;
    for (0..R) |i| ring[i] = newObj(@intCast(i));
    for (0..R) |i| {
        ring[i].next = ring[(i + 1) % R];
        ring[(i + 1) % R].hdr += 1;
    }
    for (1..R) |i| objRel(ring[i]); // ring[0] keeps its outside reference
    for (0..3) |_| c.rt_gc_collect();
    var exact = true;
    for (0..R) |i| exact = exact and count(ring[i]) == (if (i == 0) @as(u64, 2) else 1) and ring[i].val == i;
    check(freed == 0 and exact, @src(), "a referenced ring survives with exact counts");
    objRel(ring[0]);
    for (0..3) |_| c.rt_gc_collect();
    if (caps.precise) check(freed == R, @src(), "dropping the outside reference reclaims the ring");
    var st: c.KxGcStats = undefined;
    c.rt_gc_stats(&st);
    check(st.collections > 0 and st.reclaimed >= @as(i64, if (caps.precise) 2 * R else 0), @src(), "stats count the collections and reclaimed objects");
}

fn deferredRc() void {
    // Epoch: generated code never touches a traced header after initialization; every retain / release
    // goes through the log, and stores into traced fields are followed by a write barrier.
    c.rt_gc_collect(); // settle the objects acyclicAlloc released
    check(freed == 2, @src(), "logged releases from acyclicAlloc are applied at the collection");
    freed = 0;
    const live = newObj(42);
    c.rt_gc_log_inc(live);
    c.rt_gc_log_dec(live);
    c.rt_gc_collect();
    check(freed == 0 and live.val == 42, @src(), "balanced logged inc/dec keeps the object");
    // An acyclic chain: the head's last release frees the head and, through trav, the tail.
    const a = newObj(1);
    const b = newObj(2);
    a.next = b; // b's creation reference moves into a.next
    c.rt_gc_write_barrier(a);
    c.rt_gc_log_dec(a);
    c.rt_gc_collect();
    check(freed == 2, @src(), "a logged release frees a chain");
    // A garbage cycle a <-> b is found by the background trial deletion and freed at exit-drain.
    freed = 0;
    const x = newObj(10);
    const y = newObj(20);
    x.next = y; // y's creation reference
    c.rt_gc_write_barrier(x);
    y.next = x;
    c.rt_gc_log_inc(x);
    c.rt_gc_write_barrier(y);
    c.rt_gc_log_dec(x); // drop x's local reference: only the cycle is left
    for (0..3) |_| c.rt_gc_collect();
    check(freed == 2, @src(), "a logged garbage cycle is reclaimed");
    c.rt_gc_log_dec(live);
    c.rt_gc_collect();
    check(freed == 3, @src(), "the last logged release frees the live object");
    // An old-generation (stable) object whose decrement leaves it alive is deferred to a major detection
    // instead of becoming a minor root (KX_GC_DEFER_LIVE): when that decrement makes it the last way into a
    // garbage cycle, the cycle is still found.
    freed = 0;
    const p = newObj(30);
    const q = newObj(40);
    p.next = q; // q's creation reference
    c.rt_gc_write_barrier(p);
    q.next = p;
    c.rt_gc_log_inc(p);
    c.rt_gc_write_barrier(q);
    c.rt_gc_log_inc(p);
    c.rt_gc_log_dec(p); // p is a root while its local reference keeps it alive: promoted to the old generation
    c.rt_gc_collect();
    check(freed == 0 and p.val == 30 and q.val == 40, @src(), "a referenced cycle survives a detection");
    c.rt_gc_log_dec(p); // drop p's local reference: p stays alive (count 1, from q), only the cycle is left
    for (0..3) |_| c.rt_gc_collect();
    check(freed == 2, @src(), "a cycle whose last way in was a stable object is reclaimed");
}

var caps: kx.Caps = .{};

export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    caps = kx.caps(argc, argv, 2);
    const want = if (argc > 1) std.mem.span(argv[1]) else "";
    check(std.mem.eql(u8, std.mem.span(c.rt_gc_name()), want), @src(), "rt_gc_name() matches the selected collector");
    acyclicAlloc();
    storageHooks();
    if (caps.deferred) deferredRc() else {
        immediateRc();
        if (caps.cycles) trialDeletion();
    }
    var st: c.KxGcStats = undefined;
    c.rt_gc_stats(&st);
    // Found by mutation testing (rc/gc.c rt_gc_stats survived): a collector without cycle collection
    // reports no collector activity at all.
    if (!caps.cycles) check(st.collections == 0 and st.reclaimed == 0 and st.pause_ns_total == 0, @src(), "no cycle collector: all stats zero");
    check(st.pause_ns_total >= st.pause_ns_max and st.pause_ns_max >= 0, @src(), "pause_ns_total >= pause_ns_max >= 0");
    _ = c.printf("gc=%s collections=%lld reclaimed=%lld\n", c.rt_gc_name(), @as(c_longlong, st.collections), @as(c_longlong, st.reclaimed));
    if (kx.fails != 0) {
        _ = c.printf("API FAILED (%d)\n", kx.fails);
        return 1;
    }
    _ = c.printf("API OK\n");
    return 0;
}
