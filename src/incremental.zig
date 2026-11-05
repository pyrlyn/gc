//! Incremental trial deletion. Port of `incremental/gc.c`.
const kx = @import("kxgc");
const host = @import("host");
const regions = @import("common/regions.zig");
const obj = @import("common/object.zig");
const td_mod = @import("common/trial_deletion.zig");

pub const name = "incremental";
pub const caps = .{ .cycles = true, .precise = true, .asan = true, .deferred = false };

const CC_SLICE: usize = 64;
const CC_STEP_ROOTS: usize = 2000;
const CC_DEFAULT_BUDGET_US: i64 = 500;

const TD = td_mod.TrialDeletion(false);
var td = TD{};
var cc_roots = obj.PtrStack{};
var cc_trigger: usize = td_mod.CC_THRESHOLD;
var cc_running: bool = false;
var cc_budget_ns: i64 = -1;
var gc_stats = kx.Stats{};

pub export fn rt_alloc(size: i64) ?*anyopaque {
    return regions.rtAlloc(size);
}
pub export fn rt_free(p: ?*anyopaque, size: i64) void {
    regions.rtFree(p, size);
}
pub export fn rt_alloc_trace(size: i64) ?*anyopaque {
    return regions.rtAllocTrace(size);
}
pub export fn rt_free_trace(p: ?*anyopaque, size: i64) void {
    regions.rtFreeTrace(p, size);
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
    const o = p orelse return;
    obj.setColor(o, obj.PURPLE);
    if (obj.isBuffered(o)) return;
    obj.setBuffered(o);
    cc_roots.push(o);
    if (cc_roots.len >= cc_trigger and !cc_running and host.rt_rel_draining == 0) collectStep(false);
}

pub export fn rt_cc_dead(p: ?*anyopaque) void {
    const o = p orelse return;
    obj.setColor(o, obj.BLACK);
    if (!obj.isBuffered(o)) {
        if (obj.vtab(o).freemem) |f| f(o);
    }
}

fn markRoots(roots: [*]?*anyopaque, n: usize) usize {
    var kept: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const root = roots[i].?;
        if (obj.color(root) == obj.PURPLE and obj.refCount(root) > 0) {
            td.markGray(root);
            roots[kept] = root;
            kept += 1;
            continue;
        }
        obj.clearBuffered(root);
        if (obj.color(root) == obj.BLACK and obj.refCount(root) == 0) {
            if (obj.vtab(root).freemem) |f| f(root);
        }
    }
    return kept;
}

fn scanAndCollectRoots(roots: [*]?*anyopaque, kept: usize) void {
    var i: usize = 0;
    while (i < kept) : (i += 1) td.scan(roots[i].?);
    i = 0;
    while (i < kept) : (i += 1) obj.clearBuffered(roots[i].?);
    i = 0;
    while (i < kept) : (i += 1) td.collectWhite(roots[i].?);
}

fn freeGarbage() usize {
    td.releaseAcyclicChildren();
    var i: usize = 0;
    while (i < td.garbage.len) : (i += 1) {
        const g = td.garbage.at(i).?;
        if (obj.vtab(g).relo) |relo| relo(g);
    }
    var freed: usize = 0;
    i = 0;
    while (i < td.garbage.len) : (i += 1) {
        const g = td.garbage.at(i).?;
        if (obj.isBuffered(g)) continue;
        if (obj.vtab(g).freemem) |f| f(g);
        freed += 1;
    }
    td.garbage.len = 0;
    return freed;
}

fn collectSlice(roots: [*]?*anyopaque, n: usize) usize {
    const kept = markRoots(roots, n);
    scanAndCollectRoots(roots, kept);
    return freeGarbage();
}

fn budgetNs() i64 {
    if (cc_budget_ns < 0) {
        cc_budget_ns = host.getenv_i64("KX_GC_BUDGET_US", CC_DEFAULT_BUDGET_US) * 1000;
    }
    return cc_budget_ns;
}

fn runSlices(roots: [*]?*anyopaque, len: usize, unbounded_in: bool, start: i64, budget: i64, reclaimed: *usize) usize {
    var unbounded = unbounded_in;
    var done: usize = 0;
    while (done < len) {
        const n = if (unbounded) len - done else @min(len - done, CC_SLICE);
        reclaimed.* += collectSlice(roots + done, n);
        done += n;
        if (unbounded or host.rt_nanos() - start <= budget) continue;
        const first_slice = done == n;
        if (!first_slice) break;
        unbounded = true;
    }
    return done;
}

fn requeueRoots(roots: [*]?*anyopaque, from: usize, len: usize) void {
    var i = from;
    while (i < len) : (i += 1) {
        const root = roots[i].?;
        if (obj.color(root) == obj.BLACK and obj.refCount(root) > 0) obj.clearBuffered(root) else cc_roots.push(root);
    }
}

fn scheduleNextStep(roots_left: usize) void {
    cc_trigger = if (roots_left != 0) cc_roots.len + CC_STEP_ROOTS else td.threshold;
}

fn collectStep(full: bool) void {
    if (cc_running or cc_roots.len == 0) return;
    cc_running = true;
    const budget = budgetNs();
    const start = host.rt_nanos();
    var roots = cc_roots;
    cc_roots = .{};
    var reclaimed: usize = 0;
    td.traced = 0;
    td.activate();
    const nroots = roots.len;
    const done = runSlices(roots.items, nroots, full, start, budget, &reclaimed);
    requeueRoots(roots.items, done, nroots);
    roots.deinit();
    td.adaptThreshold(reclaimed);
    scheduleNextStep(nroots - done);
    gc_stats.collections += 1;
    gc_stats.reclaimed += @intCast(reclaimed);
    obj.statsAddPause(&gc_stats, host.rt_nanos() - start);
    cc_running = false;
}

pub export fn rt_gc_collect() void {
    while (cc_roots.len != 0 and !cc_running) collectStep(true);
}
pub export fn rt_gc_name() [*:0]const u8 {
    return "incremental";
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
/// Archive one_pass.c is run with KX_GC_BUDGET_US=0.
pub fn debugSetBudgetUs(us: i64) void {
    cc_budget_ns = us * 1000;
}
