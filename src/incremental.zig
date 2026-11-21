//! Incremental cycle collection: trial deletion that never stops the program for longer than one
//! step. `incremental/gc.c` runs Bacon & Rajan's MarkRoots / ScanRoots / CollectRoots over a slice
//! of the root buffer; a slice subtracts the internal references from the counts themselves, so it
//! has to trace everything its roots reach, and restore it, before the program may run again: with
//! a million live objects behind one root that was a pause of 200-340 ms. Here (docs/zig-port.md):
//!
//! - The counts are never modified. A cycle takes the roots buffered so far and counts, in header
//!   bits of its own, the references each object it reaches gets from the others (`mark`); an object
//!   with more references than that is referenced from outside, and so is everything it reaches
//!   (`scan`). The program runs between any two objects of that work, so what is left are only
//!   candidates.
//! - A candidate set is garbage when, at one instant, every member has exactly as many references
//!   as the members hold to it. That is checked batch by batch, each batch (a few seeds and the
//!   candidates they reach) in one piece: nothing in `kxgc.h` tells the collector that the program
//!   moved a reference, so the check cannot be spread over steps. A step is therefore bounded by
//!   the budget plus one batch, and one batch by the largest garbage structure, never by the heap.
//! - An object the cycle has reached is `HELD`: `rt_free_trace` keeps its memory until the cycle
//!   lets go of it, so the collector's sets never name freed memory. The buffered bit stays what
//!   `kxgc.h` says, "in the root buffer": a held object the program decrements is buffered again,
//!   for the next cycle, which is what makes a cycle that became garbage meanwhile a root again.
//! - The root buffer and the sets of a cycle are bitmaps, one bit per 8 bytes of the 16 KiB of
//!   address space they cover (1.6% of the objects' memory at most) instead of 8 bytes per object.
//! - A step runs for `KX_GC_BUDGET_US` (default 500 us) when enough roots are buffered, then every
//!   CC_WAKE new roots while a cycle is unfinished, and leaves the program at least as long as it
//!   took; less, down to nothing, as the buffer grows towards the threshold, so that a program
//!   cannot buffer garbage faster than it is collected.
const std = @import("std");
const kx = @import("kxgc");
const host = @import("host");
const regions = @import("common/regions.zig");
const obj = @import("common/object.zig");
const td_mod = @import("common/trial_deletion.zig");

pub const name = "incremental";
pub const caps = .{ .cycles = true, .precise = true, .asan = true, .deferred = false };

const CC_DEFAULT_BUDGET_US: i64 = 500;
/// Roots between two steps of an unfinished cycle.
const CC_WAKE: usize = 64;
/// Objects between two looks at the clock.
const CC_TICK: usize = 256;
/// Candidates validated in one piece, once the seeds' own structures are in.
const CC_BATCH: usize = 256;

// Header bits of a cycle, above the count, color and buffered bit of kxgc.h (generated code keeps
// them: it adds to the count and sets or clears the color).
/// Reached by the running cycle and named in its sets: `rt_free_trace` keeps the memory.
const HELD: u64 = 1 << 35;
/// Referenced from outside the objects the cycle reached, or reached from such an object.
const LIVE: u64 = 1 << 36;
/// Named in `seen`, not in `snap`.
const SEEN: u64 = 1 << 37;
/// Candidate in the batch being validated.
const CAND: u64 = 1 << 38;
/// Freed by the program while held: word 1 holds the size, the memory is freed when the cycle
/// lets go of the object.
const DEAD: u64 = 1 << 39;
/// References found from the objects reached (`mark`) or from the batch (`collect`); saturating,
/// and an object with a saturated count passes for referenced from outside.
const REF_SHIFT: u6 = 40;
const REF_ONE: u64 = 1 << REF_SHIFT;
const REF_FIELD: u64 = ~@as(u64, 0) << REF_SHIFT;
const CYCLE_BITS: u64 = HELD | LIVE | SEEN | CAND | DEAD | REF_FIELD;
const PURPLE_BITS: u64 = @as(u64, obj.PURPLE) << obj.COLOR_SHIFT;

/// More counted references than the cycle found holders for.
inline fn external(v: u64) bool {
    return (v & obj.CNT_MASK) != (v >> REF_SHIFT) or (v & REF_FIELD) == REF_FIELD;
}

inline fn word1(p: *anyopaque) *usize {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(p)) + obj.VTAB_OFFSET));
}

/// A set of object addresses: a bitmap per 16 KiB of address space that holds a member, found
/// through a hash table. Whether an object is a member is kept in its header by the callers.
const SET_SHIFT: u6 = 14;
const SET_WORDS: usize = (1 << SET_SHIFT) / 8 / 64;
/// A pool block of the largest size class.
const SET_BYTES: usize = SET_WORDS * 8;
const Bits = [SET_WORDS]u64;
const NO_KEY = std.math.maxInt(usize);

const PageSet = struct {
    keys: [*]usize = undefined,
    maps: [*]*Bits = undefined,
    len: usize = 0,
    cap: usize = 0,
    /// Open addressing; 0 or the index of the page plus one.
    table: [*]u32 = undefined,
    slots: usize = 0,
    count: usize = 0,
    last_key: usize = NO_KEY,
    last: *Bits = undefined,

    inline fn bitOf(a: usize) usize {
        return (a >> 3) & (SET_WORDS * 64 - 1);
    }

    /// `p` must not be a member.
    inline fn add(self: *PageSet, p: *anyopaque) void {
        const a = @intFromPtr(p);
        if (a >> SET_SHIFT != self.last_key) {
            @branchHint(.unlikely);
            _ = self.lookup(a >> SET_SHIFT, true);
        }
        const i = bitOf(a);
        self.last[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
        self.count += 1;
    }

    /// `p` must be a member.
    fn remove(self: *PageSet, p: *anyopaque) void {
        const a = @intFromPtr(p);
        if (a >> SET_SHIFT != self.last_key and !self.lookup(a >> SET_SHIFT, false)) return;
        const i = bitOf(a);
        self.last[i >> 6] &= ~(@as(u64, 1) << @intCast(i & 63));
        self.count -= 1;
    }

    inline fn slotOf(self: *const PageSet, key: usize) usize {
        const h = key *% @as(usize, @truncate(0x9E3779B97F4A7C15));
        return (h ^ (h >> 15)) & (self.slots - 1);
    }

    /// Makes the page of `key` the last one looked up; false when it has none and `insert` is off.
    noinline fn lookup(self: *PageSet, key: usize, insert: bool) bool {
        if (self.slots != 0) {
            var i = self.slotOf(key);
            while (self.table[i] != 0) : (i = (i + 1) & (self.slots - 1)) {
                const e = self.table[i] - 1;
                if (self.keys[e] != key) continue;
                self.last_key = key;
                self.last = self.maps[e];
                return true;
            }
        }
        if (!insert) return false;
        if (self.len == self.cap) {
            const cap = if (self.cap == 0) 64 else self.cap * 2;
            const k = if (self.cap == 0) host.malloc(cap * @sizeOf(usize)) else host.realloc(@ptrCast(self.keys), cap * @sizeOf(usize));
            const m = if (self.cap == 0) host.malloc(cap * @sizeOf(*Bits)) else host.realloc(@ptrCast(self.maps), cap * @sizeOf(*Bits));
            self.keys = @ptrCast(@alignCast(k));
            self.maps = @ptrCast(@alignCast(m));
            self.cap = cap;
        }
        const map: *Bits = @ptrCast(@alignCast(regions.rtAllocTrace(SET_BYTES)));
        map.* = @splat(0);
        self.keys[self.len] = key;
        self.maps[self.len] = map;
        self.len += 1;
        if (self.len * 2 > self.slots) self.rehash() else self.place(self.len - 1);
        self.last_key = key;
        self.last = map;
        return true;
    }

    fn place(self: *PageSet, e: usize) void {
        var i = self.slotOf(self.keys[e]);
        while (self.table[i] != 0) i = (i + 1) & (self.slots - 1);
        self.table[i] = @intCast(e + 1);
    }

    fn rehash(self: *PageSet) void {
        if (self.slots != 0) host.free(@ptrCast(self.table));
        self.slots = if (self.slots == 0) 128 else self.slots * 2;
        self.table = @ptrCast(@alignCast(host.calloc(self.slots * @sizeOf(u32))));
        var e: usize = 0;
        while (e < self.len) : (e += 1) self.place(e);
    }

    fn clear(self: *PageSet) void {
        var e: usize = 0;
        while (e < self.len) : (e += 1) regions.rtFreeTrace(self.maps[e], SET_BYTES);
        if (self.cap != 0) {
            host.free(@ptrCast(self.keys));
            host.free(@ptrCast(self.maps));
        }
        if (self.slots != 0) host.free(@ptrCast(self.table));
        self.* = .{};
    }
};

/// A walk over a set nothing is added to meanwhile; members may be removed, and those removed
/// before the walk reaches them are not returned.
const Cursor = struct {
    page: usize = 0,
    word: usize = 0,
    left: u64 = 0,

    fn next(c: *Cursor, s: *const PageSet) ?*anyopaque {
        while (true) {
            if (c.left != 0) {
                const live = c.left & s.maps[c.page][c.word - 1];
                c.left = live & (live -% 1);
                if (live == 0) continue;
                const b: usize = @ctz(live);
                return @ptrFromInt((s.keys[c.page] << SET_SHIFT) + ((c.word - 1) * 64 + b) * 8);
            }
            if (c.word == SET_WORDS) {
                c.page += 1;
                c.word = 0;
            }
            if (c.page >= s.len) return null;
            c.left = s.maps[c.page][c.word];
            c.word += 1;
        }
    }
};

const Phase = enum {
    idle,
    /// The roots leave the buffer and are held; those that died while buffered are freed.
    take,
    /// Everything the roots reach is held, and its references from held objects are counted.
    mark,
    /// Objects with more references than counted, and what they reach, are live.
    scan,
    /// Every held object is let go of: the live and the dead ones as they are, the rest (the
    /// candidates) validated in batches, the garbage among them released and freed.
    collect,
};

var phase: Phase = .idle;
/// The possible roots (buffered bit set) that no cycle has taken yet.
var pending = PageSet{};
/// The roots of the running cycle, and what it reached from them.
var snap = PageSet{};
var seen = PageSet{};
var cur = Cursor{};
var cur_in_seen = false;
/// Held objects still to traverse (`mark`, `scan`) or the batch members to (`collect`).
var work = obj.PtrStack{};
var batch = obj.PtrStack{};
/// References a dead object held to objects that are not garbage of its batch, to be released;
/// and objects whose count that brought to zero.
var ext = obj.PtrStack{};
var dying = obj.PtrStack{};

var threshold: usize = td_mod.CC_THRESHOLD;
var cc_trigger: usize = td_mod.CC_THRESHOLD;
var cc_running: bool = false;
var cc_budget_ns: i64 = -1;
var gc_stats = kx.Stats{};
/// Objects traversed by `mark` and objects reclaimed in the running cycle: the threshold adapts
/// once per cycle.
var cycle_traced: usize = 0;
var cycle_reclaimed: usize = 0;
var held_dead: usize = 0;

var step_full = false;
/// Objects of work left before the step looks at its limit again (`refill`).
var step_left: usize = 0;
var deadline: i64 = 0;
var last_end: i64 = 0;
var last_dur: i64 = 0;
/// Tests only (`debugSetStepUnits`): a bounded step ends after this many objects, whatever the
/// clock says, one runs at every possible root, and batches hold one seed.
var debug_step_units: usize = 0;

/// Counts one object of work; true when the step is over.
inline fn spent() bool {
    return spentN(1);
}

inline fn spentN(n: usize) bool {
    if (step_left > n) {
        step_left -= n;
        return false;
    }
    return refill();
}

/// The clock is read once per `CC_TICK` objects. Once the step is over every call says so.
noinline fn refill() bool {
    if (step_full) {
        step_left = std.math.maxInt(usize);
        return false;
    }
    if (debug_step_units != 0 or host.rt_nanos() >= deadline) {
        step_left = 0;
        return true;
    }
    step_left = CC_TICK;
    return false;
}

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
    const q = p orelse return;
    // Generated code frees an object right after it wrote the count, so the header is at hand
    // (alloc_drop: no difference). A caller that frees blocks it has not touched pays for the
    // read (churn, random order: 1.9 ns an operation, 2.3 with it); testing `phase` first instead
    // cost alloc_drop 0.3 ns.
    if (obj.header(q).* & HELD != 0) {
        @branchHint(.unlikely);
        return freeHeld(q, size);
    }
    regions.rtFreeTrace(q, size);
}
pub export fn rt_free_trace(p: ?*anyopaque, size: i64) void {
    freeTrace(p, size);
}

/// The program frees an object the running cycle holds: the cycle frees the memory when it lets go
/// of it. With no cycle running the bit is not the collector's (a block freed without ever having
/// had a header, as tests of the pool do).
noinline fn freeHeld(q: *anyopaque, size: i64) void {
    if (phase == .idle) return regions.rtFreeTrace(q, size);
    obj.header(q).* |= DEAD;
    word1(q).* = @intCast(size);
    held_dead += 1;
    if (held_dead % CC_WAKE != 0 or cc_running) return;
    // Memory the program has freed waits for the cycle: it goes on even if no root is buffered.
    if (host.rt_rel_draining != 0) cc_trigger = 0 else wake();
}

inline fn freeDead(x: *anyopaque) void {
    held_dead -= 1;
    regions.rtFreeTrace(x, @intCast(word1(x).*));
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
    // Out of line like C's separate translation unit: inlined into release paths it gave every
    // release a stack frame (+30% on rc_pair).
    @call(.never_inline, possibleRoot, .{p});
}

fn possibleRoot(p: ?*anyopaque) void {
    const o = p orelse return;
    const h = obj.header(o);
    const v = h.* | PURPLE_BITS;
    if (v & obj.BUF_BIT != 0) {
        h.* = v;
        return;
    }
    h.* = v | obj.BUF_BIT;
    pending.add(o);
    if (pending.count >= cc_trigger and !cc_running and host.rt_rel_draining == 0) wake();
}

pub export fn rt_cc_dead(p: ?*anyopaque) void {
    const o = p orelse return;
    obj.setColor(o, obj.BLACK);
    if (!obj.isBuffered(o)) {
        if (obj.vtab(o).freemem) |f| f(o);
    }
}

fn budgetNs() i64 {
    if (cc_budget_ns < 0) {
        cc_budget_ns = @max(host.getenv_i64("KX_GC_BUDGET_US", CC_DEFAULT_BUDGET_US), 0) *| 1000;
    }
    return cc_budget_ns;
}

/// Enough roots are buffered for a step. The program first gets as long as the last step took,
/// less the fuller the buffer is: none from the threshold on. (From twice the threshold on, the
/// buffer of a program that only makes garbage cycles held three thresholds of roots, and the
/// process half as much memory again.)
fn wake() void {
    if (debug_step_units == 0 and pending.count < threshold) {
        const room: i64 = @intCast(threshold - pending.count);
        const gap = @divTrunc(last_dur * room, @as(i64, @intCast(threshold)));
        if (host.rt_nanos() - last_end < gap) {
            cc_trigger = pending.count + CC_WAKE;
            return;
        }
    }
    step(budgetNs(), false);
}

/// One collector step: the running cycle, or a new one over the roots buffered now, until it is
/// done or (unless `full`) the budget is spent.
fn step(budget_ns: i64, full: bool) void {
    cc_running = true;
    const start = host.rt_nanos();
    step_full = full;
    step_left = if (full) std.math.maxInt(usize) else if (debug_step_units != 0) debug_step_units else CC_TICK;
    deadline = start +| budget_ns;
    if (phase == .idle) {
        snap = pending;
        pending = .{};
        cycle_traced = 0;
        cycle_reclaimed = 0;
        enter(.take);
    }
    while (true) {
        const done = switch (phase) {
            .take => take(),
            .mark => mark(),
            .scan => scan(),
            .collect => collect(),
            .idle => unreachable,
        };
        if (!done) break;
        switch (phase) {
            .take => enter(.mark),
            .mark => enter(.scan),
            .scan => enter(.collect),
            .collect => {
                std.debug.assert(snap.count == 0 and seen.count == 0);
                snap.clear();
                seen.clear();
                if (cycle_reclaimed * td_mod.CC_PRODUCTIVE_RATIO < cycle_traced) {
                    if (threshold < td_mod.CC_MAX_THRESHOLD) threshold *= 2;
                } else if (cycle_reclaimed * 2 >= cycle_traced) {
                    // Not back to CC_THRESHOLD after any productive cycle (C): with a large live
                    // structure behind the roots the threshold then went 10000, 20000, 40000,
                    // 10000, ... and two cycles of three traced the structure for little
                    // (cycles shared_200k: 141 ns a cycle, 96 with this).
                    threshold = @max(td_mod.CC_THRESHOLD, threshold / 2);
                }
                phase = .idle;
            },
            .idle => unreachable,
        }
        if (phase == .idle) break;
    }
    const end = host.rt_nanos();
    last_end = end;
    last_dur = end - start;
    cc_trigger = if (debug_step_units != 0)
        0
    else if (phase == .idle and pending.count < threshold)
        threshold
    else
        pending.count + CC_WAKE;
    gc_stats.collections += 1;
    obj.statsAddPause(&gc_stats, end - start);
    cc_running = false;
}

fn enter(p: Phase) void {
    phase = p;
    cur = .{};
    cur_in_seen = false;
}

/// The next object of `snap`, then of `seen`.
fn nextHeld() ?*anyopaque {
    if (!cur_in_seen) {
        if (cur.next(&snap)) |x| return x;
        cur = .{};
        cur_in_seen = true;
    }
    return cur.next(&seen);
}

/// Every root leaves the buffer before anything is traversed: from then on a decrement of any
/// object the cycle works on buffers it again, for the next cycle.
fn take() bool {
    while (cur.next(&snap)) |r| {
        const h = obj.header(r);
        const v = h.*;
        if (v & obj.CNT_MASK == 0) {
            // Dead while buffered (the program cleared the color and left it to the collector),
            // or being released right now, up the stack: then the release frees it.
            h.* = v & ~obj.BUF_BIT;
            snap.remove(r);
            if (v & obj.COLOR_MASK == 0) {
                if (obj.vtab(r).freemem) |f| f(r);
            }
        } else {
            h.* = (v & ~(obj.BUF_BIT | obj.COLOR_MASK | CYCLE_BITS)) | HELD;
        }
        if (spent()) return false;
    }
    return true;
}

fn mark() bool {
    while (true) {
        const x = if (work.len != 0) work.pop().? else cur.next(&snap) orelse return true;
        // Not an object that died since it was held: its fields are released.
        if (obj.refCount(x) != 0) {
            cycle_traced += 1;
            if (obj.vtab(x).trav) |trav| trav(x, markChild);
        }
        if (spent()) return false;
    }
}

fn markChild(child: ?*anyopaque) callconv(.c) void {
    const c = child orelse return;
    if (!obj.isCyclic(c)) return;
    const h = obj.header(c);
    var v = h.*;
    if (v & HELD == 0) {
        v = (v & ~CYCLE_BITS) | HELD | SEEN;
        seen.add(c);
        work.push(c);
    }
    if (v & REF_FIELD != REF_FIELD) v += REF_ONE;
    h.* = v;
}

fn scan() bool {
    while (true) {
        if (work.len != 0) {
            const x = work.pop().?;
            if (obj.refCount(x) != 0) {
                if (obj.vtab(x).trav) |trav| trav(x, liveChild);
            }
        } else {
            const x = nextHeld() orelse return true;
            const h = obj.header(x);
            const v = h.*;
            if (v & obj.CNT_MASK != 0 and v & LIVE == 0 and external(v)) {
                h.* = v | LIVE;
                work.push(x);
            }
        }
        if (spent()) return false;
    }
}

fn liveChild(child: ?*anyopaque) callconv(.c) void {
    const c = child orelse return;
    if (!obj.isCyclic(c)) return;
    const h = obj.header(c);
    if (h.* & (HELD | LIVE) != HELD) return;
    h.* |= LIVE;
    work.push(c);
}

/// A held object leaves its set and is the program's alone again.
inline fn letGo(x: *anyopaque, v: u64) void {
    (if (v & SEEN != 0) &seen else &snap).remove(x);
    obj.header(x).* = v & ~CYCLE_BITS;
}

/// Lets go of every held object. Those not live are the candidates, validated batch by batch: a
/// batch is closed under the references of its members to candidates, and its members' references
/// to each other are counted in one piece with the check: a member with as many references as
/// that, and reached from no member with more, is garbage. A member a candidate outside the batch
/// refers to fails here; if that candidate is garbage, releasing it buffers the member for the
/// next cycle.
fn collect() bool {
    const batch_max = if (debug_step_units != 0) 1 else CC_BATCH;
    while (true) {
        batch.len = 0;
        var visited: usize = 0;
        var more = true;
        while (batch.len < batch_max and visited < batch_max) {
            const s = nextHeld() orelse {
                more = false;
                break;
            };
            visited += 1;
            const v = obj.header(s).*;
            if (v & CAND != 0) continue; // joined this batch from another seed
            if (v & DEAD != 0) {
                letGo(s, v);
                freeDead(s);
            } else if (v & obj.CNT_MASK == 0 or v & LIVE != 0) {
                // Live, or its release is in progress up the stack and frees it.
                letGo(s, v);
            } else {
                join(s, v);
                while (work.len != 0) {
                    const x = work.pop().?;
                    if (obj.vtab(x).trav) |trav| trav(x, batchChild);
                }
            }
        }
        var i: usize = 0;
        while (i < batch.len) : (i += 1) {
            const x = batch.at(i).?;
            const v = obj.header(x).*;
            if (v & CAND == 0 or !external(v)) continue;
            obj.header(x).* = v & ~CAND;
            work.push(x);
            while (work.len != 0) {
                const y = work.pop().?;
                if (obj.vtab(y).trav) |trav| trav(y, failChild);
            }
        }
        if (batch.len != 0) freeGarbage();
        if (!more) return true;
        if (spentN(batch.len + visited)) return false;
    }
}

inline fn join(x: *anyopaque, v: u64) void {
    obj.header(x).* = (v & ~REF_FIELD) | CAND;
    batch.push(x);
    work.push(x);
}

fn batchChild(child: ?*anyopaque) callconv(.c) void {
    const c = child orelse return;
    if (!obj.isCyclic(c)) return;
    const h = obj.header(c);
    // A candidate no batch has taken yet: held, and neither live nor freed by the program.
    if (h.* & (HELD | LIVE | DEAD | CAND) == HELD) join(c, h.*);
    const v = h.*;
    if (v & CAND != 0 and v & REF_FIELD != REF_FIELD) h.* = v + REF_ONE;
}

fn failChild(child: ?*anyopaque) callconv(.c) void {
    const c = child orelse return;
    if (!obj.isCyclic(c)) return;
    const h = obj.header(c);
    if (h.* & CAND == 0) return;
    h.* &= ~CAND;
    work.push(c);
}

/// Releases the batch members still CAND: the references they hold to anything else, then their
/// untraced fields, then the objects; and lets go of the other members. Until then all of them are
/// held: the memory of a member the releases free stays valid while the batch names it.
fn freeGarbage() void {
    var n: usize = 0;
    var i: usize = 0;
    host.rt_trav_mode = 1; // RT_TRAV_RELEASE
    while (i < batch.len) : (i += 1) {
        const g = batch.at(i).?;
        if (obj.header(g).* & CAND == 0) continue;
        n += 1;
        if (obj.vtab(g).trav) |trav| trav(g, garbageChild);
    }
    host.rt_trav_mode = 0; // RT_TRAV_SCAN
    if (n != 0) {
        release();
        i = 0;
        while (i < batch.len) : (i += 1) {
            const g = batch.at(i).?;
            if (obj.header(g).* & CAND == 0) continue;
            if (obj.vtab(g).relo) |relo| relo(g);
        }
    }
    i = 0;
    while (i < batch.len) : (i += 1) {
        const g = batch.at(i).?;
        const v = obj.header(g).*;
        if (v & CAND == 0) {
            letGo(g, v);
            if (v & DEAD != 0) freeDead(g);
            continue;
        }
        unbuffer(g);
        letGo(g, v & ~(obj.CNT_MASK | obj.BUF_BIT));
        if (obj.vtab(g).freemem) |f| f(g);
    }
    cycle_reclaimed += n;
    gc_stats.reclaimed += @intCast(n);
}

fn garbageChild(child: ?*anyopaque) callconv(.c) void {
    const c = child orelse return;
    if (obj.isCyclic(c) and obj.header(c).* & CAND != 0) return;
    ext.push(c);
}

fn extChild(child: ?*anyopaque) callconv(.c) void {
    if (child) |c| ext.push(c);
}

/// Releases the references in `ext`. A traced object whose count that brings to zero is released
/// here the way garbage is (its references, its untraced fields, the object), without recursion.
fn release() void {
    while (true) {
        if (ext.len != 0) {
            const c = ext.pop().?;
            if (!obj.isCyclic(c)) {
                if (obj.vtab(c).rel) |rel| rel(c);
                continue;
            }
            const h = obj.header(c);
            const v = h.* - 1;
            if (v & obj.CNT_MASK == 0) {
                h.* = v;
                dying.push(c);
            } else if (v & obj.BUF_BIT != 0) {
                h.* = v | PURPLE_BITS;
            } else {
                // As generated code does after a decrement: it may have been the last reference
                // from outside a cycle.
                h.* = v | PURPLE_BITS | obj.BUF_BIT;
                pending.add(c);
            }
        } else if (dying.len != 0) {
            const d = dying.pop().?;
            host.rt_trav_mode = 1;
            if (obj.vtab(d).trav) |trav| trav(d, extChild);
            host.rt_trav_mode = 0;
            if (obj.vtab(d).relo) |relo| relo(d);
            unbuffer(d);
            if (obj.vtab(d).freemem) |f| f(d);
        } else return;
    }
}

fn unbuffer(x: *anyopaque) void {
    const h = obj.header(x);
    if (h.* & obj.BUF_BIT == 0) return;
    h.* &= ~obj.BUF_BIT;
    pending.remove(x);
}

pub export fn rt_gc_collect() void {
    while ((phase != .idle or pending.count != 0) and !cc_running) step(0, true);
}

/// Optional (not in kxgc.h): one bounded step with the caller's budget, for hosts that have idle
/// time to give, e.g. a JS/wasm event loop from requestIdleCallback or between frames. Returns the
/// roots still buffered, plus one while a cycle is unfinished: 0 when there is nothing left to do.
/// No-op while a step or a release drain is in progress.
pub export fn rt_gc_idle_step(budget_us: i64) usize {
    if (host.rt_rel_draining == 0 and !cc_running and (phase != .idle or pending.count != 0)) {
        step(@max(budget_us, 0) *| 1000, false);
    }
    return pending.count + @intFromBool(phase != .idle);
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
    return work.cap * @sizeOf(?*anyopaque);
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
/// Tests: a bounded step ends after `n` objects, whatever the clock says, and one runs at every
/// possible root (0: off).
pub fn debugSetStepUnits(n: usize) void {
    debug_step_units = n;
    cc_trigger = if (n != 0) 0 else @max(threshold, pending.count + CC_WAKE);
}
/// Tests: the header bits of a cycle, all clear once it has let go of the object.
pub fn debugCycleBits(p: *anyopaque) u64 {
    return obj.header(p).* & CYCLE_BITS;
}
/// Objects the program freed whose memory a cycle still keeps: none once no cycle runs.
pub fn debugHeldDead() usize {
    return held_dead;
}
/// Archive one_pass.c is run with KX_GC_BUDGET_US=0.
pub fn debugSetBudgetUs(us: i64) void {
    cc_budget_ns = us * 1000;
}
/// For bench/native/cycles.zig: possible roots buffered, and those of an unfinished cycle.
pub fn debugRootsLen() usize {
    return pending.count + snap.count;
}
pub const debugPoolPages = regions.debugPoolPages;
