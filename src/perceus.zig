//! Perceus RC + synchronous trial deletion. Port of `perceus/gc.c`.
const kx = @import("kxgc");
const host = @import("host");
const regions = @import("common/regions.zig");
const obj = @import("common/object.zig");
const td_mod = @import("common/trial_deletion.zig");

pub const name = "perceus";
pub const caps = .{ .cycles = true, .precise = true, .asan = true, .deferred = false };

const TD = td_mod.TrialDeletion(true, false);
var td = TD{};
var cc_roots = obj.PtrStack{};
var cc_running: bool = false;
var gc_stats = kx.Stats{};

pub export fn rt_alloc(size: i64) ?*anyopaque {
    return regions.rtAlloc(size);
}
pub export fn rt_free(p: ?*anyopaque, size: i64) void {
    regions.rtFree(p, size);
}
pub inline fn allocTrace(size: i64) ?*anyopaque {
    return regions.rtAllocTrace(size);
}
pub export fn rt_alloc_trace(size: i64) ?*anyopaque {
    return allocTrace(size);
}
pub inline fn freeTrace(p: ?*anyopaque, size: i64) void {
    regions.rtFreeTrace(p, size);
}
pub export fn rt_free_trace(p: ?*anyopaque, size: i64) void {
    freeTrace(p, size);
}
pub export fn rt_gc_mem_alloc(n: usize) ?*anyopaque {
    return regions.memAlloc(n);
}
pub export fn rt_gc_mem_calloc(n: usize) ?*anyopaque {
    return regions.memCalloc(n);
}
pub export fn rt_gc_mem_realloc(p: ?*anyopaque, n: usize) ?*anyopaque {
    return regions.memRealloc(p, n);
}
pub export fn rt_gc_mem_free(p: ?*anyopaque) void {
    regions.memFree(p);
}

pub export fn rt_cc_possible_root(p: ?*anyopaque) void {
    // Out of line like C's separate translation unit: once `PtrStack.push` became small this
    // got inlined into release paths, giving every release a stack frame (+30% on rc_pair).
    @call(.never_inline, possibleRoot, .{p});
}

fn possibleRoot(p: ?*anyopaque) void {
    const o = p orelse return;
    obj.setColor(o, obj.PURPLE);
    if (obj.isBuffered(o)) return;
    obj.setBuffered(o);
    cc_roots.push(o);
    if (cc_roots.len >= td.threshold and !cc_running and host.rt_rel_draining == 0) collectCycles();
}

pub export fn rt_cc_dead(p: ?*anyopaque) void {
    const o = p orelse return;
    obj.setColor(o, obj.BLACK);
    if (!obj.isBuffered(o)) {
        if (obj.vtab(o).freemem) |f| f(o);
    }
}

/// Compacts the live purple roots of `roots[0..n)` to the front. Freeing a root can buffer new roots,
/// which `possibleRoot` appends after `n` (and may move `roots.items`).
fn markRoots(roots: *obj.PtrStack, n: usize) usize {
    var kept: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const root = roots.at(i).?;
        if (obj.color(root) == obj.PURPLE and obj.refCount(root) > 0) {
            td.markGray(root);
            roots.set(kept, root);
            kept += 1;
        } else {
            obj.clearBuffered(root);
            if (obj.color(root) == obj.BLACK and obj.refCount(root) == 0) {
                if (obj.vtab(root).freemem) |f| f(root);
            }
        }
    }
    return kept;
}

fn freeGarbage() usize {
    td.releaseAcyclicChildren();
    var i: usize = 0;
    while (i < td.garbage.len) : (i += 1) {
        const g = td.garbage.at(i).?;
        if (obj.vtab(g).relo) |relo| relo(g);
    }
    i = 0;
    while (i < td.garbage.len) : (i += 1) {
        const g = td.garbage.at(i).?;
        if (obj.vtab(g).freemem) |f| f(g);
    }
    const freed = td.garbage.len;
    td.garbage.len = 0;
    return freed;
}

fn collectCycles() void {
    if (cc_running or cc_roots.len == 0) return;
    cc_running = true;
    const start = host.rt_nanos();
    // This collection's roots are cc_roots[0..n). Roots buffered while it runs are appended after
    // them and kept for the next one, in the same buffer. C moves them to a fresh buffer, which then
    // regrew from its initial capacity to the threshold (a realloc and copy per doubling) every time.
    const roots = &cc_roots;
    const n = roots.len;
    td.traced = 0;
    td.activate();
    const kept = markRoots(roots, n);
    var i: usize = 0;
    while (i < kept) : (i += 1) td.scan(roots.at(i).?);
    i = 0;
    while (i < kept) : (i += 1) {
        obj.clearBuffered(roots.at(i).?);
        td.collectWhite(roots.at(i).?);
    }
    const reclaimed = freeGarbage();
    const late = roots.len - n;
    @memmove(roots.items[0..late], roots.items[n..roots.len]);
    roots.len = late;
    td.adaptThreshold(reclaimed);
    // A drain (no collection while it runs) or a threshold since lowered can leave the buffer far
    // larger than the next collection needs: free it, as C does after every collection.
    if (roots.cap > 2 * @max(td.threshold, late) + obj.PTR_STACK_INITIAL_CAPACITY) {
        var fresh = obj.PtrStack{};
        for (roots.items[0..late]) |r| fresh.push(r);
        roots.deinit();
        roots.* = fresh;
    }
    gc_stats.collections += 1;
    gc_stats.reclaimed += @intCast(reclaimed);
    obj.statsAddPause(&gc_stats, host.rt_nanos() - start);
    cc_running = false;
    if (cc_roots.len >= td.threshold) collectCycles();
}

pub export fn rt_gc_collect() void {
    while (cc_roots.len != 0 and !cc_running) collectCycles();
}
pub export fn rt_gc_name() [*:0]const u8 {
    return "perceus";
}
pub export fn rt_gc_stats(out: *kx.Stats) void {
    out.* = gc_stats;
}

pub inline fn logInc(p: ?*anyopaque) void {
    _ = p;
    host.rt_panic("rt_gc_log_inc without deferred RC");
}
pub inline fn logDec(p: ?*anyopaque) void {
    _ = p;
    host.rt_panic("rt_gc_log_dec without deferred RC");
}
pub inline fn writeBarrier(o: ?*anyopaque) void {
    _ = o;
}
pub export fn rt_gc_log_inc(p: ?*anyopaque) void {
    logInc(p);
}
pub export fn rt_gc_log_dec(p: ?*anyopaque) void {
    logDec(p);
}
pub export fn rt_gc_write_barrier(o: ?*anyopaque) void {
    writeBarrier(o);
}
pub export fn rt_gc_root_hint(p: ?*anyopaque) void {
    const o = p orelse return;
    if ((obj.header(o).* & kx.CNT_MASK) != 0) rt_cc_possible_root(o);
}
pub export fn rt_gc_free_later(p: ?*anyopaque) void {
    _ = p;
    host.rt_panic("rt_gc_free_later without deferred RC");
}

/// For the traversal test: pending work-stack capacity in bytes.
pub fn debugWorkBytes() usize {
    return td.work.cap * @sizeOf(?*anyopaque);
}

pub fn debugRefCount(p: *anyopaque) u64 {
    return obj.refCount(p);
}
pub fn debugColor(p: *anyopaque) u2 {
    return obj.color(p);
}
pub fn debugIsBuffered(p: *anyopaque) bool {
    return obj.isBuffered(p);
}
pub fn debugInitialCap() usize {
    return obj.PTR_STACK_INITIAL_CAPACITY;
}
/// For bench/native/cycles.zig: possible roots currently buffered.
pub fn debugRootsLen() usize {
    return cc_roots.len;
}
pub const debugPoolPages = regions.debugPoolPages;
