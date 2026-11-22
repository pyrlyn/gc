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
//!   the budget plus the check of one batch, and one batch by the largest garbage structure, never
//!   by the heap. What the check found garbage the program cannot reach: it is released and freed
//!   in steps like everything else.
//! - An object a cycle found live is old (`STABLE`). A minor cycle, over the roots buffered since
//!   the last, does not go into old objects: it costs what the young objects behind its roots cost,
//!   not the live heap. The roots that are old, and those of a minor cycle that stopped at an old
//!   object, stay buffered in a set of their own (`deferred`) for a major cycle, which goes
//!   everywhere. One is due when a quarter as many roots are deferred as the last one traversed
//!   objects (up to four times as many while majors free little), or when the heap has grown by
//!   half since the last. A deferred root that died keeps its memory until a major cycle, or until
//!   the heap grows: then the deferred roots are gone through (`sweep`).
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
/// `major_mult` at most: a major cycle waits for four times as many deferred roots as the last
/// one traversed objects.
const MAJOR_MULT_MAX: usize = 16;
/// Pool pages (16 KiB) the heap grows by before a major cycle is due whatever was deferred (or
/// half the heap the last one left, if that is more); before `deferred` is gone through for dead
/// roots (or 32 bytes per root); and between two steps of an unfinished cycle.
const GROW_MAJOR: usize = 64;
const GROW_SWEEP: usize = 16;
const GROW_STEP: usize = 8;

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
/// Old: a cycle found it live. Minor cycles do not go into it. It outlives the cycle, so it is not
/// one of `CYCLE_BITS`; a major cycle works it out again.
const STABLE: u64 = 1 << 40;
/// Buffered in `deferred`, not in `pending`.
const DEFERRED: u64 = 1 << 41;
/// References found from the objects reached (`mark`) or from the batch (`collect`); saturating
/// (22 bits), and an object with a saturated count passes for referenced from outside.
const REF_SHIFT: u6 = 42;
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
        // The pool may come back here for memory (`onGrow`): not for a cycle, this set is in pieces.
        set_growing = true;
        const map: *Bits = @ptrCast(@alignCast(regions.rtAllocTrace(SET_BYTES)));
        set_growing = false;
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
    /// No cycle: the deferred roots that died since they were deferred are freed.
    sweep,
};

var phase: Phase = .idle;
/// The possible roots (buffered bit set) that no cycle has taken yet.
var pending = PageSet{};
/// The roots of the running cycle, and what it reached from them.
var snap = PageSet{};
var seen = PageSet{};
/// The possible roots only a major cycle can decide: old objects, and the roots a minor cycle let
/// go of after it had stopped at an old object.
var deferred = PageSet{};
var set_growing = false;
var cur = Cursor{};
var cur_in_seen = false;
/// Held objects still to traverse (`mark`, `scan`) or the batch members to (`collect`).
var work = obj.PtrStack{};
var batch = obj.PtrStack{};
/// References a dead object held to objects that are not garbage of its batch, to be released;
/// and objects whose count that brought to zero.
var ext = obj.PtrStack{};
var dying = obj.PtrStack{};
/// What is left to do with the batch `collect` validated last (`freeGarbage`), how far that is, the
/// garbage in it, and whether `collect` has more held objects to go to.
const FreeStage = enum { refs, release, fields, memory, done };
var free_stage: FreeStage = .done;
var free_i: usize = 0;
var free_n: usize = 0;
var batch_more = false;

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
/// The running cycle took `deferred` and goes into old objects.
var cycle_major = false;
/// The running minor cycle stopped at an old object: what it found live may be garbage through it.
var hit_stable = false;
/// Roots the running cycle found dead in the buffer.
var cycle_zombies: usize = 0;
/// Roots deferred since the last major cycle began; objects that one traversed; and how many
/// quarters of those must be deferred before the next: more while majors find little.
var weight: usize = 0;
var major_traced: usize = 0;
var major_mult: usize = 1;
/// Pool pages when the last major cycle ended, when `deferred` was last gone through, and when
/// the last step ended.
var major_pages: usize = 0;
var sweep_pages: usize = 0;
var step_pages: usize = 0;
var debug_turn: usize = 0;

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

/// Microseconds to nanoseconds, negative as 0 and saturating. Clamped before a plain multiply:
/// LLVM turns `*|` on a value known non-negative into @llvm.umul.fix.sat.i63, which the KotlinX JS
/// backend (--target=js translates this collector's bitcode) cannot translate.
fn usToNs(us: i64) i64 {
    return std.math.clamp(us, 0, std.math.maxInt(i64) / 1000) * 1000;
}

fn budgetNs() i64 {
    if (cc_budget_ns < 0) {
        cc_budget_ns = usToNs(host.getenv_i64("KX_GC_BUDGET_US", CC_DEFAULT_BUDGET_US));
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
    step(budgetNs(), false, false);
}

/// The heap outgrew what the last major cycle left of it by half (1 MiB at least): garbage that
/// goes through old objects is found whatever the number of roots deferred.
fn growDue() bool {
    return regions.debugPoolPages() - major_pages >= @max(GROW_MAJOR, major_pages / 2);
}

fn majorDue() bool {
    return weight >= @max(td_mod.CC_THRESHOLD, major_traced / 4 * major_mult) or growDue();
}

/// Dead deferred roots keep their memory: `deferred` is gone through when the heap has grown by
/// 32 bytes per root since (one header read per 32 bytes allocated at most).
fn sweepDue() bool {
    return regions.debugPoolPages() - sweep_pages >= @max(GROW_SWEEP, deferred.count / 512);
}

/// The pool is about to take a page it may have to ask the system for (`regions.grow_hook`). The
/// program may be buffering nothing: the roots of old objects stay buffered, their decrements do
/// not come here, so what the heap's growth makes due starts here, and an unfinished cycle goes on.
fn onGrow() void {
    if (cc_running or set_growing or host.rt_rel_draining != 0) return;
    if (phase != .idle) {
        if (regions.debugPoolPages() - step_pages < GROW_STEP) return;
    } else if (deferred.count == 0 or !(sweepDue() or growDue())) return;
    step(budgetNs(), false, false);
}

/// Starts a cycle: a minor one over the roots buffered since the last, which stops at old objects;
/// a major one over the deferred roots, which goes everywhere; or a sweep of the deferred roots.
/// `drain`: whatever is buffered, not only what is due. False when there is nothing to start.
fn begin(drain: bool) bool {
    const debug = debug_step_units != 0;
    const old = deferred.count != 0;
    const Kind = enum { none, minor, major, sweep };
    var kind: Kind = if (pending.count != 0 and (drain or debug or pending.count >= threshold))
        .minor
    else if (old and (drain or debug or majorDue()))
        .major
    else if (old and sweepDue())
        .sweep
    else
        .none;
    if (debug and old) {
        // Tests: every kind in turn, whatever is due.
        debug_turn +%= 1;
        switch (debug_turn % 3) {
            1 => kind = .major,
            2 => kind = .sweep,
            else => {},
        }
    }
    cycle_traced = 0;
    cycle_reclaimed = 0;
    cycle_zombies = 0;
    hit_stable = false;
    switch (kind) {
        .none => return false,
        .minor => {
            cycle_major = false;
            snap = pending;
            pending = .{};
            enter(.take);
        },
        .major => {
            cycle_major = true;
            snap = deferred;
            deferred = .{};
            weight = 0;
            enter(.take);
        },
        .sweep => enter(.sweep),
    }
    return true;
}

/// One collector step: the running cycle, or a new one, until it is done or (unless `full`) the
/// budget is spent.
fn step(budget_ns: i64, full: bool, drain: bool) void {
    regions.grow_hook = onGrow;
    cc_running = true;
    defer cc_running = false;
    const start = host.rt_nanos();
    step_full = full;
    step_left = if (full) std.math.maxInt(usize) else if (debug_step_units != 0) debug_step_units else CC_TICK;
    deadline = start +| budget_ns;
    if (phase == .idle and !begin(drain)) {
        cc_trigger = if (debug_step_units != 0) 0 else @max(threshold, pending.count + CC_WAKE);
        return;
    }
    while (true) {
        const done = switch (phase) {
            .take => take(),
            .mark => mark(),
            .scan => scan(),
            .collect => collect(),
            .sweep => sweep(),
            .idle => unreachable,
        };
        if (!done) break;
        switch (phase) {
            .take => enter(.mark),
            .mark => enter(.scan),
            .scan => enter(.collect),
            .sweep => {
                sweep_pages = regions.debugPoolPages();
                phase = .idle;
            },
            .collect => {
                std.debug.assert(snap.count == 0 and seen.count == 0);
                snap.clear();
                seen.clear();
                if (cycle_major) {
                    // Old objects are traversed again by every major cycle: the less of them
                    // one frees, the more roots the next waits for.
                    const got = cycle_reclaimed + cycle_zombies;
                    if (got * td_mod.CC_PRODUCTIVE_RATIO < cycle_traced) {
                        if (major_mult < MAJOR_MULT_MAX) major_mult *= 2;
                    } else if (got * 2 >= cycle_traced) {
                        major_mult = @max(1, major_mult / 2);
                    }
                    major_traced = cycle_traced;
                    major_pages = regions.debugPoolPages();
                    sweep_pages = major_pages;
                } else if (cycle_reclaimed * td_mod.CC_PRODUCTIVE_RATIO < cycle_traced) {
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
    step_pages = regions.debugPoolPages();
    cc_trigger = if (debug_step_units != 0)
        0
    else if (phase == .idle and pending.count < threshold and !(deferred.count != 0 and majorDue()))
        threshold
    else
        pending.count + CC_WAKE;
    gc_stats.collections += 1;
    obj.statsAddPause(&gc_stats, end - start);
}

fn enter(p: Phase) void {
    phase = p;
    cur = .{};
    cur_in_seen = false;
    free_stage = .done;
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
            h.* = v & ~(obj.BUF_BIT | DEFERRED | STABLE);
            snap.remove(r);
            if (v & obj.COLOR_MASK == 0) {
                cycle_zombies += 1;
                if (obj.vtab(r).freemem) |f| f(r);
            }
        } else if (v & STABLE != 0 and !cycle_major) {
            // An old object stays buffered, for a major cycle.
            h.* = v | DEFERRED;
            snap.remove(r);
            deferred.add(r);
            weight += 1;
        } else {
            h.* = (v & ~(obj.BUF_BIT | obj.COLOR_MASK | CYCLE_BITS | DEFERRED | STABLE)) | HELD;
        }
        if (spent()) return false;
    }
    return true;
}

/// Frees the deferred roots that died since: the program left them to the collector. One being
/// released right now, up the stack, still has its color.
fn sweep() bool {
    while (cur.next(&deferred)) |r| {
        const h = obj.header(r);
        const v = h.*;
        if (v & (obj.CNT_MASK | obj.COLOR_MASK) == 0) {
            h.* = v & ~(obj.BUF_BIT | DEFERRED | STABLE);
            deferred.remove(r);
            if (obj.vtab(r).freemem) |f| f(r);
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
        if (v & STABLE != 0 and !cycle_major) {
            hit_stable = true;
            return;
        }
        v = (v & ~(CYCLE_BITS | STABLE)) | HELD | SEEN;
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

/// A held object leaves its set and is the program's alone again; one found live is old from
/// now on. A root that a minor cycle lets go of after it stopped at an old object may be garbage
/// through that object: it is buffered again, for a major cycle (colored as a buffered object
/// is: one without a color and without references has been left to the collector).
inline fn letGo(x: *anyopaque, v: u64) void {
    var nv = v & ~(CYCLE_BITS | STABLE);
    if (v & LIVE != 0) nv |= STABLE;
    if (v & SEEN != 0) {
        seen.remove(x);
    } else {
        snap.remove(x);
        if (hit_stable and v & (DEAD | obj.BUF_BIT) == 0 and v & obj.CNT_MASK != 0) {
            nv |= STABLE | DEFERRED | obj.BUF_BIT | PURPLE_BITS;
            deferred.add(x);
            weight += 1;
        }
    }
    obj.header(x).* = nv;
}

/// Lets go of every held object. Those not live are the candidates, validated batch by batch: a
/// batch is closed under the references of its members to candidates, and its members' references
/// to each other are counted in one piece with the check: a member with as many references as
/// that, and reached from no member with more, is garbage. A member a candidate outside the batch
/// refers to fails here; if that candidate is garbage, releasing it buffers the member for the
/// next cycle. Only that check is one piece: what it found garbage the program cannot reach any
/// more, so the batch is released and freed like everything else, in steps.
fn collect() bool {
    const batch_max = if (debug_step_units != 0) 1 else CC_BATCH;
    while (true) {
        if (free_stage != .done) {
            if (!freeGarbage()) return false;
            if (!batch_more) return true;
        }
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
        batch_more = more;
        free_stage = .refs;
        free_i = 0;
        free_n = 0;
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
/// untraced fields, then the objects; and lets go of the other members. Until the last stage all of
/// them are held and CAND says which are garbage: the memory of a member the releases free stays
/// valid while the batch names it, and no reference between two of them is released. False when
/// the step is over first.
fn freeGarbage() bool {
    while (true) switch (free_stage) {
        .refs => {
            host.rt_trav_mode = 1; // RT_TRAV_RELEASE
            defer host.rt_trav_mode = 0; // RT_TRAV_SCAN
            while (free_i < batch.len) {
                const g = batch.at(free_i).?;
                free_i += 1;
                if (obj.header(g).* & CAND == 0) continue;
                free_n += 1;
                if (obj.vtab(g).trav) |trav| trav(g, garbageChild);
                if (spent()) return false;
            }
            free_stage = .release;
        },
        .release => {
            if (!release()) return false;
            free_i = 0;
            free_stage = if (free_n != 0) .fields else .memory;
        },
        .fields => {
            while (free_i < batch.len) {
                const g = batch.at(free_i).?;
                free_i += 1;
                if (obj.header(g).* & CAND == 0) continue;
                if (obj.vtab(g).relo) |relo| relo(g);
                if (spent()) return false;
            }
            free_i = 0;
            free_stage = .memory;
        },
        .memory => {
            while (free_i < batch.len) {
                const g = batch.at(free_i).?;
                free_i += 1;
                const v = obj.header(g).*;
                if (v & CAND == 0) {
                    letGo(g, v);
                    if (v & DEAD != 0) freeDead(g);
                } else {
                    unbuffer(g);
                    letGo(g, v & ~(obj.CNT_MASK | obj.BUF_BIT | DEFERRED));
                    if (obj.vtab(g).freemem) |f| f(g);
                }
                if (spent()) return false;
            }
            cycle_reclaimed += free_n;
            gc_stats.reclaimed += @intCast(free_n);
            free_stage = .done;
        },
        .done => return true,
    };
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
/// False when the step is over first: nothing refers to an object in `dying`, and the references
/// in `ext` are still counted.
fn release() bool {
    while (true) {
        if (ext.len == 0 and dying.len == 0) return true;
        if (ext.len != 0) {
            const c = ext.pop().?;
            if (!obj.isCyclic(c)) {
                if (obj.vtab(c).rel) |rel| rel(c);
                if (spent()) return false;
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
        }
        if (spent()) return false;
    }
}

fn unbuffer(x: *anyopaque) void {
    const h = obj.header(x);
    const v = h.*;
    if (v & obj.BUF_BIT == 0) return;
    h.* = v & ~(obj.BUF_BIT | DEFERRED);
    (if (v & DEFERRED != 0) &deferred else &pending).remove(x);
}

pub export fn rt_gc_collect() void {
    while ((phase != .idle or pending.count != 0 or deferred.count != 0) and !cc_running) step(0, true, true);
}

/// Optional (not in kxgc.h): one bounded step with the caller's budget, for hosts that have idle
/// time to give, e.g. a JS/wasm event loop from requestIdleCallback or between frames. Returns the
/// roots still buffered (deferred ones too: idle time is when a major cycle costs the program
/// nothing), plus one while a cycle is unfinished: 0 when there is nothing left to do.
/// No-op while a step or a release drain is in progress.
pub export fn rt_gc_idle_step(budget_us: i64) usize {
    if (host.rt_rel_draining == 0 and !cc_running and (phase != .idle or pending.count != 0 or deferred.count != 0)) {
        step(usToNs(budget_us), false, true);
    }
    return pending.count + deferred.count + @intFromBool(phase != .idle);
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
/// For bench/native/cycles.zig: possible roots no cycle has decided yet, and those of an
/// unfinished one. Not the deferred roots of old objects, which only wait to be looked at again.
pub fn debugRootsLen() usize {
    return pending.count + (if (cycle_major) 0 else snap.count);
}
/// Tests: roots waiting for a major cycle.
pub fn debugDeferredLen() usize {
    return deferred.count;
}
pub const debugPoolPages = regions.debugPoolPages;
