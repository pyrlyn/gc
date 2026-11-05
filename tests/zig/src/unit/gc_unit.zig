//! Port of compiler/gc/tests/unit/gc_unit.c: unit tests of the kxgc.h interface, linked with the runtime
//! and one implementation (see src/runner.zig). Objects are hand-built the way generated code lays them
//! out: { header, vtable, fields... }. Same cases, same assertions and output as the C original;
//! capabilities come as arguments ("cycles", "precise") instead of -DKX_CAP_*.
const kx = @import("kx.zig");
const c = kx.c;

const Obj = extern struct { hdr: u64, vt: *c.KxVTab, next: ?*Obj, val: i64 };
var freed: i64 = 0;
var released_other: i64 = 0;
fn objFree(p: ?*anyopaque) callconv(.c) void {
    freed += 1;
    c.rt_free_trace(p, @sizeOf(Obj));
}
fn objTrav(p: ?*anyopaque, f: c.kx_visit_fn) callconv(.c) void {
    f.?(@as(*Obj, @ptrCast(@alignCast(p))).next);
}
fn objRelo(_: ?*anyopaque) callconv(.c) void {
    released_other += 1;
}
var cyc_vt: c.KxVTab = .{ .rel = objRel, .trav = objTrav, .relo = objRelo, .freemem = objFree, .cyclic = @ptrFromInt(1) };
/// Generated-code release path for a cyclic class (NativeBackend.kt @rel.C / @relz.C).
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
    o.* = .{ .hdr = 1, .vt = &cyc_vt, .next = null, .val = v };
    return o;
}

const N = 300000;
var objs: [N]?*Obj = undefined;

export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    const caps = kx.caps(argc, argv, 1);
    const check = kx.check;
    _ = c.printf("gc=%s\n", c.rt_gc_name());
    // acyclic region
    for (0..100000) |i| {
        const p: [*]i64 = @ptrCast(@alignCast(c.rt_alloc(48)));
        p[0] = 1;
        p[5] = @intCast(i);
        check(p[5] == i, @src(), "p[5] == i");
        c.rt_free(p, 48);
    }
    // acyclic chain freed by RC
    freed = 0;
    {
        const a = newObj(1);
        const b = newObj(2);
        a.next = b;
        objRel(a);
        check(freed == 2, @src(), "freed == 2");
    }
    // shared object survives until the last reference
    freed = 0;
    {
        const a = newObj(1);
        a.hdr += 1;
        objRel(a);
        check(freed == 0, @src(), "freed == 0");
        check(a.val == 1, @src(), "a->val == 1");
        objRel(a);
        c.rt_gc_collect();
        check(freed == 1, @src(), "freed == 1");
    }
    // reachable cycle survives a collection
    {
        const a = newObj(10);
        const b = newObj(20);
        a.next = b;
        b.next = a;
        b.hdr += 1;
        a.hdr += 1; // a: 1 (b), +1 local
        objRel(a); // drop local: a reachable only from b, b from a and a local
        c.rt_gc_collect();
        check(a.val == 10 and b.val == 20 and a.next == b, @src(), "a->val == 10 && b->val == 20 && a->next == b");
        if (caps.cycles) {
            freed = 0;
            released_other = 0;
            objRel(b); // last outside reference: a<->b is garbage
            for (0..3) |_| c.rt_gc_collect();
            var st: c.KxGcStats = undefined;
            c.rt_gc_stats(&st);
            check(st.collections > 0, @src(), "st.collections > 0");
            // a conservative collector may still see a or b in a dead stack slot
            if (caps.precise) check(released_other >= 2 or freed >= 2, @src(), "released_other >= 2 || freed >= 2");
        }
    }
    // runtime storage hooks
    {
        var m: [*]i64 = @ptrCast(@alignCast(c.rt_gc_mem_calloc(64)));
        for (0..8) |i| check(m[i] == 0, @src(), "m[i] == 0");
        m[7] = 42;
        m = @ptrCast(@alignCast(c.rt_gc_mem_realloc(m, 4096)));
        check(m[7] == 42, @src(), "m[7] == 42");
        c.rt_gc_mem_free(m);
        const zz = c.rt_gc_mem_realloc(null, 16);
        check(zz != null, @src(), "z != NULL");
        c.rt_gc_mem_free(zz);
    }
    if (caps.cycles) {
        // no collection starts while deferred releases run, however many roots are buffered
        var before: c.KxGcStats = undefined;
        var during: c.KxGcStats = undefined;
        for (0..N) |i| {
            objs[i] = newObj(@intCast(i));
            objs[i].?.hdr += 1;
        }
        c.rt_gc_stats(&before);
        c.rt_rel_draining = 1;
        for (0..N) |i| objRel(objs[i]);
        c.rt_rel_draining = 0;
        c.rt_gc_stats(&during);
        check(during.collections == before.collections, @src(), "during.collections == before.collections");
        for (0..N) |i| {
            objRel(objs[i]);
            objs[i] = null; // bdwgc would scan a dangling pointer
        }
        c.rt_gc_collect();
        // stress: many self cycles
        for (0..200000) |i| {
            const s = newObj(@intCast(i));
            s.next = s;
            s.hdr += 1;
            objRel(s);
        }
        c.rt_gc_collect();
        var s1: c.KxGcStats = undefined;
        c.rt_gc_stats(&s1);
        check(s1.reclaimed >= 190000, @src(), "s1.reclaimed >= 190000");
    }
    var st: c.KxGcStats = undefined;
    c.rt_gc_stats(&st);
    _ = c.printf("collections=%lld reclaimed=%lld pause_max_us=%lld\n", @as(c_longlong, st.collections), @as(c_longlong, st.reclaimed), @as(c_longlong, @divTrunc(st.pause_ns_max, 1000)));
    if (kx.fails != 0) {
        _ = c.printf("UNIT FAILED (%d)\n", kx.fails);
        return 1;
    }
    _ = c.printf("UNIT OK\n");
    return 0;
}
