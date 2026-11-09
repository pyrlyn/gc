//! Incremental trial deletion. Port of `incremental/gc.c` with a different step scheduler.
//!
//! Trial deletion is correct for any subset of the candidate roots, so a step runs MarkRoots /
//! ScanRoots / CollectRoots over the buffer in slices under a per-step time budget
//! (`KX_GC_BUDGET_US`, default 500 us). Where the scheduler differs from C (docs/zig-port.md):
//!
//! - The buffer is consumed in place from `cc_head` and roots buffered meanwhile are appended:
//!   a bounded step neither copies the roots it leaves nor reallocates the buffer.
//! - As in C, later slices of a step drop the roots an earlier slice scanned black (live), and those
//!   left at the end of the step leave the buffer (BLACK in the buffer must keep meaning dead). C
//!   rescans every left-over root for that after every bounded step (O(backlog) cache misses); here
//!   the rescan runs only when the step did blacken a buffered root
//!   (`TrialDeletion.blackened_buffered`), and the slice's own roots are unbuffered before Scan so
//!   that they do not count.
//! - Slice size follows a cost model `t = fixed + per_root * n` fitted from the slices run. `fixed`
//!   is the live graph the roots share, re-traced by every slice; slices grow until it is amortized
//!   (see `SliceModel.plan`), where C's 64-root slices re-traced it 64 roots at a time. A step stops
//!   before a slice predicted to cross the budget. A shared graph over the budget gets one slice
//!   per step with as much root work as the graph costs (C: every root in one pass, a pause that
//!   grows with the buffer); C's one-pass rule remains for a first slice over the budget before
//!   the model has a slope.
//! - Pacing: an unfinished step resumes after half as many new roots as it processed, so the
//!   backlog shrinks instead of growing whenever a step processes fewer than 2000 roots; a backlog
//!   over CC_BACKLOG_FACTOR x threshold is processed in one pass.
const std = @import("std");
const kx = @import("kxgc");
const host = @import("host");
const regions = @import("common/regions.zig");
const obj = @import("common/object.zig");
const td_mod = @import("common/trial_deletion.zig");

pub const name = "incremental";
pub const caps = .{ .cycles = true, .precise = true, .asan = true, .deferred = false };

const CC_SLICE_MIN: usize = 64;
const CC_SLICE_MAX: usize = 1 << 16;
const CC_BACKLOG_FACTOR: usize = 4;
const CC_DEFAULT_BUDGET_US: i64 = 500;

const TD = td_mod.TrialDeletion(false, true);
var td = TD{};
/// items[0..cc_head) are consumed slots, items[cc_head..len) the buffered possible roots.
var cc_roots = obj.PtrStack{};
var cc_head: usize = 0;
var cc_trigger: usize = td_mod.CC_THRESHOLD;
var cc_running: bool = false;
var cc_budget_ns: i64 = -1;
var gc_stats = kx.Stats{};
var model = SliceModel{};
/// Reclaimed by the steps of the current cycle (buffer non-empty until it empties). `td.traced`
/// also spans the cycle: the threshold adapts once per cycle, as after a one-pass collection.
/// Per step, every bounded step would look unproductive and double it.
var cycle_reclaimed: usize = 0;
/// Tests only (`debugSetFixedSlice`): bounded steps run exactly one slice of this many roots.
var debug_fixed_slice: usize = 0;

inline fn pendingRoots() usize {
    return cc_roots.len - cc_head;
}

/// Cost of one slice of n roots, `fixed + per_root * n`, refitted after every bounded slice.
const SliceModel = struct {
    slice: usize = CC_SLICE_MIN,
    fixed_ns: f64 = 0,
    per_root_ns: f64 = -1, // unknown until two slices of different sizes ran
    last_n: usize = 0,
    last_ns: f64 = 0,

    fn observe(m: *SliceModel, n: usize, ns: i64) void {
        const nf: f64 = @floatFromInt(n);
        const tf: f64 = @floatFromInt(@max(ns, 0));
        // Slope only from sizes at least 25% apart: from a short tail slice next to a full one,
        // clock noise over a small difference in size would dominate it.
        const dn = if (n > m.last_n) n - m.last_n else m.last_n - n;
        if (m.last_n != 0 and dn * 4 >= @max(n, m.last_n)) {
            const slope = @max(0, (tf - m.last_ns) / (nf - @as(f64, @floatFromInt(m.last_n))));
            m.per_root_ns = if (m.per_root_ns < 0) slope else (m.per_root_ns + slope) / 2;
        }
        if (m.per_root_ns >= 0) m.fixed_ns = (m.fixed_ns + @max(0, tf - m.per_root_ns * nf)) / 2;
        m.last_n = n;
        m.last_ns = tf;
    }

    fn predictNs(m: *const SliceModel, n: usize) f64 {
        const nf: f64 = @floatFromInt(n);
        if (m.per_root_ns >= 0) return m.fixed_ns + m.per_root_ns * nf;
        if (m.last_n == 0) return 0;
        return m.last_ns * nf / @as(f64, @floatFromInt(m.last_n));
    }

    /// The fixed part (a graph the roots share) is at least the budget, so no slice fits in it.
    /// A step then runs one `sharedSlice` instead of first paying for a bounded slice that
    /// re-traces the graph anyway. Every slice refits the model, so a graph that shrinks brings
    /// bounded steps back.
    fn sharedOverBudget(m: *const SliceModel, budget_ns: i64) bool {
        return m.per_root_ns >= 0 and m.fixed_ns >= @as(f64, @floatFromInt(budget_ns));
    }

    /// Roots per slice once the shared graph alone is over budget: as much root work as the graph
    /// costs (pause about 2 x fixed, re-tracing at most half of the collector's time).
    fn sharedSlice(m: *const SliceModel) usize {
        const want = if (m.per_root_ns > 0) m.fixed_ns / m.per_root_ns else std.math.inf(f64);
        if (want >= @as(f64, @floatFromInt(CC_SLICE_MAX))) return CC_SLICE_MAX;
        return @max(CC_SLICE_MIN, @as(usize, @intFromFloat(want)));
    }

    /// Next slice size, moving at most x2 / /2 per slice. With the slope unknown it grows: the
    /// second size is what gives the slope. Per-root time per slice: `fixed` while two slices fit
    /// in the budget (re-tracing costs at most half), what is left of the budget after `fixed`,
    /// and never less than a quarter of the budget.
    fn plan(m: *SliceModel, budget_ns: i64) void {
        const lo = @max(m.slice / 2, CC_SLICE_MIN);
        const hi = @min(m.slice * 2, CC_SLICE_MAX);
        if (m.per_root_ns <= 0) {
            m.slice = hi;
            return;
        }
        const b: f64 = @floatFromInt(@max(budget_ns, 0));
        const roots_ns = @max(@min(m.fixed_ns, b - m.fixed_ns), b / 4);
        const want = roots_ns / m.per_root_ns;
        m.slice = if (want >= @as(f64, @floatFromInt(hi))) hi else @max(lo, @as(usize, @intFromFloat(want)));
    }
};

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
    if (pendingRoots() >= cc_trigger and !cc_running and host.rt_rel_draining == 0) collectStep(false, budgetNs());
}

pub export fn rt_cc_dead(p: ?*anyopaque) void {
    const o = p orelse return;
    obj.setColor(o, obj.BLACK);
    if (!obj.isBuffered(o)) {
        if (obj.vtab(o).freemem) |f| f(o);
    }
}

/// MarkRoots for one slice: keeps (compacted to the front) the roots still PURPLE with a live count
/// and mark-grays them. Every other root leaves the buffer: re-blackened (live) or dead while
/// buffered (BLACK, count 0), which is when it gets freed.
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

/// ScanRoots + CollectRoots. The slice's roots leave the buffer before Scan rather than after (C):
/// with `claim_skips_buffered` off nothing in between reads the bit, and Scan then counts only
/// other slices' roots in `blackened_buffered`.
fn scanAndCollectRoots(roots: [*]?*anyopaque, kept: usize) void {
    var i: usize = 0;
    while (i < kept) : (i += 1) obj.clearBuffered(roots[i].?);
    i = 0;
    while (i < kept) : (i += 1) td.scan(roots[i].?);
    i = 0;
    while (i < kept) : (i += 1) td.collectWhite(roots[i].?);
}

/// After a step that scanned buffered roots black: those still buffered are live and leave the
/// buffer now, as their own slice would have done. One must not stay: once the program drops it, a
/// step started while its fields are being released would take the black count-zero object for a
/// dead one (markRoots) and free it under the release.
fn dropLiveBlackRoots() void {
    var w = cc_head;
    var i = cc_head;
    while (i < cc_roots.len) : (i += 1) {
        const root = cc_roots.items[i].?;
        if (obj.color(root) == obj.BLACK and obj.refCount(root) > 0) {
            obj.clearBuffered(root);
            continue;
        }
        cc_roots.items[w] = root;
        w += 1;
    }
    cc_roots.len = w;
}

/// Releases the acyclic children and untraced fields of everything CollectWhite found, then frees it.
/// Garbage still buffered (a later slice's root) stays BLACK with count 0; its slice frees it.
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

/// Full trial deletion over roots[0..n). `roots` may be stale afterwards: freeing garbage can
/// buffer new roots and grow the buffer.
fn collectSlice(roots: [*]?*anyopaque, n: usize) usize {
    const kept = markRoots(roots, n);
    scanAndCollectRoots(roots, kept);
    return freeGarbage();
}

fn budgetNs() i64 {
    if (cc_budget_ns < 0) {
        cc_budget_ns = @max(host.getenv_i64("KX_GC_BUDGET_US", CC_DEFAULT_BUDGET_US), 0) *| 1000;
    }
    return cc_budget_ns;
}

const StepMode = enum {
    /// slices within the budget
    bounded,
    /// one `SliceModel.sharedSlice`: a shared graph over the budget
    shared,
    /// every root up to `end` in one slice: rt_gc_collect, a backlog over the cap, or (C's rule)
    /// a first slice over the budget before the model knows why
    all,
};

/// Slices over the buffered roots up to `end` (roots buffered during the step wait for the next one).
/// Bounded, it stops before a slice the model predicts to end over the budget; at least one runs.
fn runSlices(end: usize, mode_in: StepMode, start: i64, budget: i64, reclaimed: *usize) void {
    var mode = mode_in;
    var first = true;
    var now = start;
    while (cc_head < end) {
        const slice = switch (mode) {
            .all => end - cc_head,
            .shared => model.sharedSlice(),
            .bounded => if (debug_fixed_slice != 0) debug_fixed_slice else model.slice,
        };
        const n = @min(end - cc_head, slice);
        const roots = cc_roots.items + cc_head;
        cc_head += n;
        reclaimed.* += collectSlice(roots, n);
        const t0 = now;
        now = host.rt_nanos();
        model.observe(n, now - t0);
        if (mode != .bounded or debug_fixed_slice != 0) break;
        model.plan(budget);
        const elapsed: f64 = @floatFromInt(now - start);
        const b: f64 = @floatFromInt(budget);
        if (first and elapsed > b and model.per_root_ns < 0) {
            // C: a graph shared by the roots would be re-traced by every further slice. The
            // one-pass slice also gives the model its slope.
            mode = .all;
            continue;
        }
        first = false;
        if (elapsed + model.predictNs(@min(end - cc_head, model.slice)) > b) break;
    }
}

/// Moves the pending roots to the front once at least half the buffer is consumed (amortized O(1)
/// per root; one memmove, no per-root header reads).
fn compactRoots() void {
    const left = pendingRoots();
    if (left == 0) {
        cc_roots.len = 0;
        cc_head = 0;
    } else if (cc_head >= left) {
        std.mem.copyForwards(?*anyopaque, cc_roots.items[0..left], cc_roots.items[cc_head..cc_roots.len]);
        cc_roots.len = left;
        cc_head = 0;
    }
}

/// Next trigger: an unfinished step resumes after half as many new roots as it processed (so the
/// backlog shrinks), otherwise the adaptive threshold.
fn scheduleNextStep(processed: usize) void {
    const left = pendingRoots();
    cc_trigger = if (left != 0) left + @max(processed / 2, CC_SLICE_MIN) else td.threshold;
}

/// One collector step: slices until the roots buffered at its start are done or (unless `full`)
/// the budget is spent.
fn collectStep(full: bool, budget: i64) void {
    if (cc_running or pendingRoots() == 0) return;
    cc_running = true;
    const start = host.rt_nanos();
    const end = cc_roots.len;
    const head0 = cc_head;
    const mode: StepMode = if (full or pendingRoots() > CC_BACKLOG_FACTOR * td.threshold)
        .all
    else if (debug_fixed_slice == 0 and model.sharedOverBudget(budget))
        .shared
    else
        .bounded;
    var reclaimed: usize = 0;
    td.activate();
    td.blackened_buffered = 0;
    runSlices(end, mode, start, budget, &reclaimed);
    const processed = cc_head - head0;
    if (td.blackened_buffered != 0 and pendingRoots() != 0) dropLiveBlackRoots();
    compactRoots();
    cycle_reclaimed += reclaimed;
    if (pendingRoots() == 0) {
        td.adaptThreshold(cycle_reclaimed);
        td.traced = 0;
        cycle_reclaimed = 0;
    }
    scheduleNextStep(processed);
    gc_stats.collections += 1;
    gc_stats.reclaimed += @intCast(reclaimed);
    obj.statsAddPause(&gc_stats, host.rt_nanos() - start);
    cc_running = false;
}

pub export fn rt_gc_collect() void {
    while (pendingRoots() != 0 and !cc_running) collectStep(true, budgetNs());
}

/// Optional (not in kxgc.h): one bounded step with the caller's budget, for hosts that have idle
/// time to give, e.g. a JS/wasm event loop from requestIdleCallback or between frames. Returns the
/// roots still buffered. No-op while a step or a release drain is in progress. Like
/// KX_GC_BUDGET_US, a budget below the cost of re-tracing a shared graph is exceeded by one
/// slice (`SliceModel.sharedSlice`).
pub export fn rt_gc_idle_step(budget_us: i64) usize {
    if (host.rt_rel_draining == 0) collectStep(false, @max(budget_us, 0) *| 1000);
    return pendingRoots();
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
/// Tests: a bounded step runs exactly one slice of `n` roots, whatever the clock says (0: off).
pub fn debugSetFixedSlice(n: usize) void {
    debug_fixed_slice = n;
}
/// Archive one_pass.c is run with KX_GC_BUDGET_US=0.
pub fn debugSetBudgetUs(us: i64) void {
    cc_budget_ns = us * 1000;
}
/// For bench/native/cycles.zig: possible roots currently buffered.
pub fn debugRootsLen() usize {
    return pendingRoots();
}
