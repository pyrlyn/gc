//! Native port of bench/ops/ops.c: per-operation mutator cost (ns/op).
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

var sink: i64 = 0;
var head: ?*Obj = null;
var tail: ?*Obj = null;

fn objFree(p: ?*anyopaque) callconv(.c) void {
    // Inline freeTrace (not the export) so Darwin no-LTO matches C LTO of
    // `obj_free` → `rt_free_trace` → `slab_free`.
    gc.freeTrace(p, @sizeOf(Obj));
}
fn objTrav(p: ?*anyopaque, f: ?kx.VisitFn) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(p));
    f.?(o.prev);
    f.?(o.next);
}
fn objRelo(_: ?*anyopaque) callconv(.c) void {}
fn objRel(p: ?*anyopaque) callconv(.c) void {
    if (comptime gc.caps.deferred) {
        gc.logDec(p);
        return;
    }
    const o: *Obj = @ptrCast(@alignCast(p orelse return));
    const c1 = o.hdr -% 1;
    if (c1 & kx.CNT_MASK != 0) {
        if (c1 & kx.BUF_BIT != 0) {
            o.hdr = c1 | (@as(u64, 3) << kx.COLOR_SHIFT);
            return;
        }
        o.hdr = c1 | (@as(u64, 3) << kx.COLOR_SHIFT);
        gc.rt_cc_possible_root(p);
        return;
    }
    o.hdr = c1;
    objRel(o.prev);
    objRel(o.next);
    objRelo(p);
    if (o.hdr & kx.BUF_BIT != 0) {
        o.hdr &= ~(@as(u64, 3) << kx.COLOR_SHIFT);
        return;
    }
    objFree(p);
}

var vt: kx.VTab = .{ .rel = objRel, .trav = objTrav, .relo = objRelo, .freemem = objFree, .cyclic = @ptrFromInt(1) };

inline fn retain(p: ?*Obj) void {
    if (comptime gc.caps.deferred) {
        gc.logInc(p);
        return;
    }
    if (p) |o| o.hdr += 1;
}
inline fn release(p: ?*Obj) void {
    // C deferred ops.c: `#define RELEASE(p) rt_gc_log_dec(p)` (macro, not obj_rel).
    // Going through callconv(.c) objRel here was a real extra call on Darwin no-LTO.
    if (comptime gc.caps.deferred) {
        gc.logDec(p);
        return;
    }
    objRel(p);
}
inline fn storeNext(o: *Obj, v: ?*Obj) void {
    retain(v);
    const old = o.next;
    if (comptime gc.caps.deferred) {
        @atomicStore(?*Obj, &o.next, v, .release);
        gc.writeBarrier(o);
    } else {
        o.next = v;
    }
    release(old);
}
inline fn storePrev(o: *Obj, v: ?*Obj) void {
    retain(v);
    const old = o.prev;
    if (comptime gc.caps.deferred) {
        @atomicStore(?*Obj, &o.prev, v, .release);
        gc.writeBarrier(o);
    } else {
        o.prev = v;
    }
    release(old);
}

inline fn newObj(v: i64) *Obj {
    // C new_obj: field stores, no struct-wide write. allocTrace never returns
    // null (OOM panics), matching `Obj *o = rt_alloc_trace(sizeof(Obj))`.
    const o: *Obj = @ptrCast(@alignCast(gc.allocTrace(@sizeOf(Obj)).?));
    o.hdr = 1;
    o.vt = &vt;
    o.prev = null;
    o.next = null;
    o.val = v;
    return o;
}

fn opRc(n: i64, live: []?*Obj) void {
    const mask: usize = live.len - 1;
    const nn: usize = @intCast(n);
    var i: usize = 0;
    while (i < nn) : (i += 1) {
        const o = live[i & mask].?;
        retain(o);
        sink += o.val;
        release(o);
    }
}
fn opStore(n: i64, live: []?*Obj) void {
    // C: live[(i * 7 + 3) & (nl - 1)] — nl is a power of two. @mod() is a
    // division and was the field_store codegen gap vs clang, not LTO.
    const mask: usize = live.len - 1;
    const nn: usize = @intCast(n);
    var i: usize = 0;
    while (i < nn) : (i += 1) {
        const o = live[i & mask].?;
        storeNext(o, live[(i *% 7 + 3) & mask]);
    }
}
fn opAlloc(n: i64, live: []?*Obj) void {
    _ = live;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const o = newObj(i);
        sink += o.val;
        release(o);
    }
}

fn unlink_(e: *Obj) void {
    const p = e.prev;
    const n = e.next;
    retain(p);
    retain(n);
    if (p == null) {
        const old = head;
        retain(n);
        head = n;
        release(old);
    } else storeNext(p.?, n);
    if (n == null) {
        const old = tail;
        retain(p);
        tail = p;
        release(old);
    } else storePrev(n.?, p);
    release(p);
    release(n);
}
fn front(e: *Obj) void {
    storePrev(e, null);
    storeNext(e, head);
    if (head) |h| storePrev(h, e) else {
        retain(e);
        tail = e;
    }
    retain(e);
    const old = head;
    head = e;
    release(old);
}
fn opLru(n: i64, live: []?*Obj) void {
    var x: u64 = 1;
    const mask: u64 = live.len - 1;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        const e = live[@intCast((x >> 33) & mask)].?;
        if (e.prev != null) {
            unlink_(e);
            front(e);
        }
    }
}

const Op = struct { name: [:0]const u8, f: *const fn (i64, []?*Obj) void };

fn median(r: []f64) f64 {
    std.mem.sort(f64, r, {}, std.sort.asc(f64));
    return r[r.len / 2];
}

fn parseI64(s: [*:0]const u8) !i64 {
    return std.fmt.parseInt(i64, std.mem.span(s), 10);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    const n: i64 = if (argv.len > 1) try parseI64(argv[1]) else 4_000_000;
    const only: ?[]const u8 = if (argv.len > 2) std.mem.span(argv[2]) else null;
    const nl: usize = 1 << 16;
    const live_raw = gc.rt_gc_mem_alloc(@sizeOf(?*Obj) * nl).?;
    const live: []?*Obj = @as([*]?*Obj, @ptrCast(@alignCast(live_raw)))[0..nl];
    var i: usize = 0;
    while (i < nl) : (i += 1) live[i] = newObj(@intCast(i));
    i = 0;
    while (i < nl) : (i += 1) front(live[i].?);
    const ops = [_]Op{
        .{ .name = "rc_pair", .f = opRc },
        .{ .name = "field_store", .f = opStore },
        .{ .name = "alloc_drop", .f = opAlloc },
        .{ .name = "lru_move", .f = opLru },
    };
    for (ops) |op| {
        if (only) |want| if (!std.mem.eql(u8, want, op.name)) continue;
        var r: [5]f64 = undefined;
        var rep: usize = 0;
        while (rep < 5) : (rep += 1) {
            const t0 = host.rt_nanos();
            op.f(n, live);
            r[rep] = @as(f64, @floatFromInt(host.rt_nanos() - t0)) / @as(f64, @floatFromInt(n));
        }
        _ = std.c.printf("%s %s %.2f\n", gc.rt_gc_name(), op.name.ptr, median(&r));
    }
    var st: kx.Stats = undefined;
    gc.rt_gc_stats(&st);
    _ = std.c.printf("%s pause_ms %.1f\n", gc.rt_gc_name(), @as(f64, @floatFromInt(st.pause_ns_total)) / 1e6);
    // Peak RSS from this process (no argv-to-exec wrapper). Linux ru_maxrss is KiB;
    // host.peakRssKb normalizes Darwin bytes → KiB.
    _ = std.c.printf("%s peak_rss_kb %lld\n", gc.rt_gc_name(), @as(c_longlong, host.peakRssKb()));
}
