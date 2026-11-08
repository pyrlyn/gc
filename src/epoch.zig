//! Epoch collector: deferred RC + concurrent cycle collection.
//! Port of `epoch/gc.c` (Bacon & Rajan concurrent trial deletion). Parallel
//! MarkGray/Scan helpers, incremental major, side-minor and early-validation
//! are implemented on one collector thread (equivalent to KX_GC_THREADS=1 /
//! KX_GC_INC_MAJOR=0). Semantics of logs, CRC trial deletion, Sigma/Delta,
//! generations, return-to-mutator and exit drain match the C.
const std = @import("std");
const builtin = @import("builtin");
const kx = @import("kxgc");
const host = @import("host");
const obj = @import("common/object.zig");
const regions = @import("common/regions.zig");

pub const name = "epoch";
pub const caps = .{ .cycles = true, .precise = true, .asan = true, .deferred = true };

const PAGE_SHIFT = 16;
const PAGE: usize = 1 << PAGE_SHIFT;
const PAGE_BITS_LOG = 31;
const CLASSES = 32;
const LOG_CAP = 32768;
const LOG_MIN = 2048;
const LOG_PER_ROOT = 4;
const LOG_FLOOR_DEFAULT = 512;
const ALLOC_CUT: usize = 1024;
const Q_ADAPT_START = 4;
const Q_ADAPT_MIN = 2;
const Q_ADAPT_MAX = 16;
const C_MAX_THRESHOLD = 1 << 18;
const MAJOR_RATIO: i64 = 4;
const OP_INC: usize = 0;
const OP_DEC: usize = 1;
const OP_MOD: usize = 2;
const OP_ROOT: usize = 3;

const DIRTY_BIT: u64 = 1 << 35;
const CAND_BIT: u64 = 1 << 36;
const DEAD_BIT: u64 = 1 << 37;
const ZOMBIE_BIT: u64 = 1 << 38;
const STABLE_BIT: u64 = 1 << 39;
const CRC_SHIFT: u6 = 40;
const CRC_MAX: u64 = 0x7fffff;
const CRC_MASK: u64 = CRC_MAX << CRC_SHIFT;

var gc_st = kx.Stats{};
var page_bits: ?[*]std.atomic.Value(u64) = null;

fn regAdd(addr: usize) void {
    const pg = addr >> PAGE_SHIFT;
    if (pg >> PAGE_BITS_LOG != 0) host.rt_panic("epoch GC: heap address outside the page bitmap");
    const bits = page_bits.?;
    _ = bits[pg >> 6].fetchOr(@as(u64, 1) << @intCast(pg & 63), .release);
}

fn isTraced(p: ?*anyopaque) bool {
    const q = p orelse return false;
    const pg = @intFromPtr(q) >> PAGE_SHIFT;
    if (pg >> PAGE_BITS_LOG != 0 or page_bits == null) return false;
    return (page_bits.?[pg >> 6].load(.acquire) >> @intCast(pg & 63)) & 1 != 0;
}

const libc_mm = struct {
    extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, off: isize) *anyopaque;
    extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
    extern "c" fn madvise(addr: *anyopaque, len: usize, advice: c_int) c_int;
};

fn mapAnon(bytes: usize, noreserve: bool) [*]u8 {
    const prot: c_int = 1 | 2; // PROT_READ | PROT_WRITE
    var flags: c_int = if (comptime builtin.os.tag == .macos)
        0x0002 | 0x1000 // MAP_PRIVATE | MAP_ANON
    else
        0x0002 | 0x0020; // MAP_PRIVATE | MAP_ANONYMOUS
    if (noreserve and comptime builtin.os.tag == .linux) flags |= 0x4000; // MAP_NORESERVE
    const p = libc_mm.mmap(null, bytes, prot, flags, -1, 0);
    if (p == std.c.MAP_FAILED) host.oom();
    return @ptrCast(p);
}

fn ensureBits() void {
    if (page_bits != null) return;
    const bytes = (@as(usize, 1) << PAGE_BITS_LOG) / 8;
    page_bits = @ptrCast(@alignCast(mapAnon(bytes, true)));
}

const SLAB_CHUNK: usize = 2 << 20;
const SLAB_DIR_TOP: usize = 1 << (PAGE_BITS_LOG - 16);
const SLAB_RESIDENT_KEEP: i64 = 16;

const Slab = extern struct {
    next: ?*Slab = null,
    prev: ?*Slab = null,
    free: ?*anyopaque = null,
    base: [*]u8 = undefined,
    bump: [*]u8 = undefined,
    live: u32 = 0,
    cls: u16 = 0,
    in_partial: u8 = 0,
    resident: u8 = 1,
};

var slab_chunk: ?[*]u8 = null;
var slab_chunk_end: [*]u8 = undefined;
var slab_dir: [SLAB_DIR_TOP]?[*]?*Slab = @splat(null);
var slab_cur: [CLASSES + 1]?*Slab = @splat(null);
var slab_partial: [CLASSES + 1]?*Slab = @splat(null);
var slab_pool: ?*Slab = null;
var slab_pending = obj.PtrStack{};
var slab_release: i32 = -1;
var slab_keep: i64 = -1;
var slab_pool_resident: i64 = 0;

fn madvAdvice() c_int {
    if (comptime builtin.os.tag == .macos) return std.c.MADV.FREE_REUSABLE;
    return 4; // MADV_DONTNEED
}

fn madv(from: *anyopaque, len: usize) void {
    if (len == 0) return;
    _ = libc_mm.madvise(from, len, madvAdvice());
}

fn pageAlloc(bytes: usize) *anyopaque {
    ensureBits();
    dbg_slab_bytes += @intCast(bytes);
    var p: *anyopaque = undefined;
    if (bytes == PAGE) {
        if (slab_chunk == null or slab_chunk.? == slab_chunk_end) {
            const want = SLAB_CHUNK + PAGE;
            const mapped = mapAnon(want, false);
            const raw_addr = @intFromPtr(mapped);
            const aligned = (raw_addr + PAGE - 1) & ~@as(usize, PAGE - 1);
            if (aligned > raw_addr) _ = libc_mm.munmap(@ptrFromInt(raw_addr), aligned - raw_addr);
            if (aligned + SLAB_CHUNK < raw_addr + want) {
                _ = libc_mm.munmap(@ptrFromInt(aligned + SLAB_CHUNK), raw_addr + want - (aligned + SLAB_CHUNK));
            }
            slab_chunk = @ptrFromInt(aligned);
            slab_chunk_end = @ptrFromInt(aligned + SLAB_CHUNK);
        }
        p = @ptrCast(slab_chunk.?);
        slab_chunk.? += PAGE;
    } else {
        if (std.c.posix_memalign(@ptrCast(&p), PAGE, bytes) != 0) host.oom();
    }
    var o: usize = 0;
    while (o < bytes) : (o += PAGE) regAdd(@intFromPtr(p) + o);
    return p;
}

inline fn slabOf(p: *anyopaque) ?*Slab {
    const pg = @intFromPtr(p) >> PAGE_SHIFT;
    const d = slab_dir[pg >> 16] orelse return null;
    return d[pg & 0xffff];
}

fn slabNew() *Slab {
    const base: [*]u8 = @ptrCast(pageAlloc(PAGE));
    const pg = @intFromPtr(base) >> PAGE_SHIFT;
    var d = slab_dir[pg >> 16];
    if (d == null) {
        // 512 KiB, one entry per 64 KiB page: anonymous zero pages so only the touched
        // entries are resident (calloc may memset a recycled block).
        const raw = mapAnon((1 << 16) * @sizeOf(?*Slab), false);
        d = @ptrCast(@alignCast(raw));
        slab_dir[pg >> 16] = d;
    }
    const s: *Slab = @ptrCast(@alignCast(host.calloc(@sizeOf(Slab))));
    s.base = base;
    s.resident = 1;
    d.?[pg & 0xffff] = s;
    return s;
}

fn partialUnlink(s: *Slab, cls: usize) void {
    if (s.prev) |prev| prev.next = s.next else slab_partial[cls] = s.next;
    if (s.next) |next| next.prev = s.prev;
    s.next = null;
    s.prev = null;
    s.in_partial = 0;
}

// C: `__attribute__((noinline)) void *slab_refill` — keep the slab_alloc hot path small.
noinline fn slabRefill(cls: usize) *anyopaque {
    var s = slab_partial[cls];
    if (s) |taken| {
        partialUnlink(taken, cls);
    } else if (slab_pool) |pooled| {
        slab_pool = pooled.next;
        pooled.next = null;
        if (pooled.resident != 0) slab_pool_resident -= 1;
        pooled.resident = 1;
        pooled.free = null;
        pooled.bump = pooled.base;
        pooled.live = 0;
        s = pooled;
    } else {
        const fresh = slabNew();
        fresh.bump = fresh.base;
        s = fresh;
    }
    const slab = s.?;
    slab.cls = @intCast(cls);
    slab_cur[cls] = slab;
    var p: *anyopaque = undefined;
    if (slab.free) |free_cell| {
        p = free_cell;
        const next: *?*anyopaque = @ptrCast(@alignCast(free_cell));
        slab.free = next.*;
    } else {
        p = @ptrCast(slab.bump);
        slab.bump += cls << 3;
    }
    slab.live += 1;
    return p;
}

inline fn slabAlloc(cls: usize) *anyopaque {
    // C slab_alloc: likely current slab, free-list then bump, else noinline refill.
    const s = slab_cur[cls];
    if (s != null) {
        @branchHint(.likely);
        const slab = s.?;
        if (slab.free) |free_cell| {
            const next: *?*anyopaque = @ptrCast(@alignCast(free_cell));
            slab.free = next.*;
            slab.live += 1;
            return free_cell;
        }
        const next_bump = slab.bump + (cls << 3);
        if (@intFromPtr(next_bump) <= @intFromPtr(slab.base) + PAGE) {
            const p: *anyopaque = @ptrCast(slab.bump);
            slab.bump = next_bump;
            slab.live += 1;
            return p;
        }
    }
    return slabRefill(cls);
}

inline fn slabFree(p: *anyopaque, cls: usize) void {
    // C slab_free does not null-check slab_of: a traced cell always has a slab.
    const s = slabOf(p).?;
    const next: *?*anyopaque = @ptrCast(@alignCast(p));
    next.* = s.free;
    s.free = p;
    if (s == slab_cur[cls]) {
        s.live -= 1;
        return;
    }
    s.live -= 1;
    if (s.live == 0) {
        if (s.in_partial != 0) partialUnlink(s, cls);
        slab_pending.push(s);
    } else if (s.in_partial == 0) {
        s.in_partial = 1;
        s.prev = null;
        s.next = slab_partial[cls];
        if (s.next) |n| n.prev = s;
        slab_partial[cls] = s;
    }
}

fn slabCmp(_: void, a: ?*anyopaque, b: ?*anyopaque) bool {
    const sa: *Slab = @ptrCast(@alignCast(a.?));
    const sb: *Slab = @ptrCast(@alignCast(b.?));
    return @intFromPtr(sa.base) < @intFromPtr(sb.base);
}

fn slabFlush() void {
    if (slab_pending.len == 0) return;
    if (slab_keep < 0) {
        slab_keep = host.getenv_i64("KX_GC_SLAB_KEEP", SLAB_RESIDENT_KEEP);
        if (slab_keep < 0) slab_keep = 0;
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i < slab_pending.len) : (i += 1) {
        const s: *Slab = @ptrCast(@alignCast(slab_pending.at(i).?));
        if (s.live != 0 or s == slab_cur[s.cls]) continue;
        s.next = slab_pool;
        slab_pool = s;
        if (slab_pool_resident < slab_keep) {
            slab_pool_resident += 1;
            continue;
        }
        s.resident = 0;
        slab_pending.set(n, s);
        n += 1;
    }
    if (n > 1) std.mem.sort(?*anyopaque, slab_pending.items[0..n], {}, slabCmp);
    i = 0;
    while (i < n) {
        var j = i + 1;
        while (j < n) {
            const prev: *Slab = @ptrCast(@alignCast(slab_pending.at(j - 1).?));
            const nxt: *Slab = @ptrCast(@alignCast(slab_pending.at(j).?));
            if (@intFromPtr(nxt.base) != @intFromPtr(prev.base) + PAGE) break;
            j += 1;
        }
        const from: *Slab = @ptrCast(@alignCast(slab_pending.at(i).?));
        madv(@ptrCast(from.base), (j - i) * PAGE);
        i = j;
    }
    slab_pending.len = 0;
}

const Big = extern struct { next: ?*Big, size: usize };
var free_list: [CLASSES + 1]?*anyopaque = @splat(null);
var bump: ?[*]u8 = null;
var bump_end: [*]u8 = undefined;
var big_free: ?*Big = null;

pub export fn rt_alloc(size: i64) ?*anyopaque {
    return host.malloc(@intCast(size));
}
pub export fn rt_free(p: ?*anyopaque, size: i64) void {
    _ = size;
    host.free(p);
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
    host.free(p);
}

var big_madvise: i32 = -1;
noinline fn allocBig(size: i64) *anyopaque {
    const bytes = (@as(usize, @intCast(size)) + PAGE - 1) & ~@as(usize, PAGE - 1);
    var b = big_free;
    var prev: *?*Big = &big_free;
    while (b) |blk| {
        if (blk.size == bytes) {
            prev.* = blk.next;
            return @ptrCast(blk);
        }
        prev = &blk.next;
        b = blk.next;
    }
    return pageAlloc(bytes);
}

noinline fn initSlabRelease() void {
    const e = std.c.getenv("KX_GC_SLAB_RELEASE");
    slab_release = if (e != null and e.?[0] == '0') 0 else 1;
}

noinline fn allocNoSlab(cls: usize) *anyopaque {
    if (free_list[cls]) |p| {
        const next: *?*anyopaque = @ptrCast(@alignCast(p));
        free_list[cls] = next.*;
        return p;
    }
    const need = cls << 3;
    if (bump == null or @intFromPtr(bump.?) + need > @intFromPtr(bump_end)) {
        const slab: [*]u8 = @ptrCast(pageAlloc(PAGE));
        bump = slab;
        bump_end = slab + PAGE;
    }
    const p: *anyopaque = @ptrCast(bump.?);
    bump.? += need;
    return p;
}

fn bigRelease(p: *anyopaque, bytes: usize) void {
    if (big_madvise < 0) {
        const e = std.c.getenv("KX_GC_MADVISE");
        big_madvise = if (e != null and e.?[0] == '0') 0 else 1;
    }
    if (big_madvise == 0) return;
    const os_page = std.heap.pageSize();
    if (bytes < 2 * os_page) return;
    const from: [*]u8 = @ptrCast(p);
    madv(@ptrCast(from + os_page), bytes - os_page);
}

pub inline fn allocTrace(size: i64) ?*anyopaque {
    // Keep this body tiny so Darwin no-LTO inlines it into newObj / op_alloc
    // the way C -flto inlines rt_alloc_trace → slab_alloc. Cold paths are noinline.
    // (C's t_allocs/t_frees debug counters are never read by this port: not kept.)
    if (ret_pos < ret_local.len) freePaced();
    alloc_left -%= 1;
    if (alloc_left == 0) {
        @branchHint(.unlikely);
        allocCut();
    }
    const cls = (@as(usize, @intCast(size)) + 7) >> 3;
    if (cls > CLASSES) {
        @branchHint(.unlikely);
        return allocBig(size);
    }
    if (slab_release < 0) {
        @branchHint(.unlikely);
        initSlabRelease();
    }
    if (slab_release != 0) return slabAlloc(cls);
    return allocNoSlab(cls);
}

pub export fn rt_alloc_trace(size: i64) ?*anyopaque {
    return allocTrace(size);
}

pub inline fn freeTrace(p: ?*anyopaque, size: i64) void {
    const q = p orelse return;
    const cls = (@as(usize, @intCast(size)) + 7) >> 3;
    if (cls > CLASSES) {
        const bytes = (@as(usize, @intCast(size)) + PAGE - 1) & ~@as(usize, PAGE - 1);
        const b: *Big = @ptrCast(@alignCast(q));
        b.size = bytes;
        b.next = big_free;
        big_free = b;
        bigRelease(q, bytes);
        return;
    }
    if (slab_release > 0) {
        slabFree(q, cls);
        return;
    }
    const next: *?*anyopaque = @ptrCast(@alignCast(q));
    next.* = free_list[cls];
    free_list[cls] = q;
}

pub export fn rt_free_trace(p: ?*anyopaque, size: i64) void {
    freeTrace(p, size);
}

pub export fn rt_cc_possible_root(p: ?*anyopaque) void {
    _ = p;
    host.rt_panic("epoch GC: rt_cc_possible_root");
}
pub export fn rt_cc_dead(p: ?*anyopaque) void {
    _ = p;
    host.rt_panic("epoch GC: rt_cc_dead");
}

const Log = struct {
    next: ?*Log = null,
    n: usize = 0,
    seq: u64 = 0,
    frees: obj.PtrStack = .{},
    a: [LOG_CAP]usize = undefined,
};

var log_cap: std.atomic.Value(usize) = std.atomic.Value(usize).init(512);
var log_cap_fixed: bool = false;
var log_boost: std.atomic.Value(usize) = std.atomic.Value(usize).init(1);
var c_threshold: usize = LOG_MIN / LOG_PER_ROOT;
var c_min_threshold: usize = LOG_MIN / LOG_PER_ROOT;
var log_floor: usize = LOG_FLOOR_DEFAULT;
var c_pure: bool = false;
var max_queued: usize = 0;
var q_fixed: bool = false;
var mu: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var cv_work: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER;
var cv_done: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER;

fn lock() void {
    _ = std.c.pthread_mutex_lock(&mu);
}
fn unlock() void {
    _ = std.c.pthread_mutex_unlock(&mu);
}
fn waitWork() void {
    _ = std.c.pthread_cond_wait(&cv_work, &mu);
}
fn waitDone() void {
    _ = std.c.pthread_cond_wait(&cv_done, &mu);
}
fn signalWork() void {
    _ = std.c.pthread_cond_signal(&cv_work);
}
fn broadcastDone() void {
    _ = std.c.pthread_cond_broadcast(&cv_done);
}
var cur: ?*Log = null;
var q_head: ?*Log = null;
var q_tail: ?*Log = null;
var log_pool: ?*Log = null;
var pool_len: usize = 0; // guarded by mu
var q_len: usize = 0;
var handed: u64 = 0;
var applied: u64 = 0;
var m_applied: u64 = 0;
var ret_shared = obj.PtrStack{};
var ret_local = obj.PtrStack{};
var ret_pos: usize = 0;
var full_req: bool = false;
var full_done: u64 = 0;
var shutting: bool = false;
var coll_started: bool = false;
var in_boundary: bool = false;
var defer_live: bool = true;
var boundary_keep: i64 = 0;
/// Mutator-only entry limit of `cur`: log_cap when the log was started, lowered by allocCut.
var log_lim: usize = 0;
/// Traced allocations a log may still make before allocCut ends it.
var alloc_left: usize = ALLOC_CUT;

/// Garbage of a log comes back only after the collector applied it, and up to max_queued + 3 logs are
/// in flight (filling, queued, applying, returned), so allocation-heavy logs at log_cap 4096 held ~1 MiB
/// of dead cells (alloc_drop: 3.7 MiB of slabs for a 2.6 MiB live set). A log that made ALLOC_CUT
/// traced allocations ends at its next entry; logs that allocate little keep the full log_cap
/// (shorter logs cost rc_pair / lru_move a lot more boundaries for no memory gain).
noinline fn allocCut() void {
    alloc_left = ALLOC_CUT;
    const l = cur orelse return;
    if (l.n + 1 < log_lim) {
        log_lim = l.n + 1;
        dbg_alloc_cuts += 1;
    }
}

fn logNew() *Log {
    log_lim = log_cap.load(.monotonic);
    alloc_left = ALLOC_CUT;
    if (log_pool) |l| {
        log_pool = l.next;
        pool_len -= 1;
        l.n = 0;
        l.next = null;
        l.frees.len = 0;
        return l;
    }
    // C malloc + n/next/frees only. Do not `l.* = .{}` — that writes the 256 KiB
    // `a[]` on every new log (mutator-visible when field_store fills a log).
    // Own anonymous mapping, not malloc: only the entries actually written become
    // resident, and a trimmed log goes back to the OS (malloc kept ~256 KiB
    // regions plus zone metadata dirty per log).
    const l: *Log = @ptrCast(@alignCast(mapAnon(@sizeOf(Log), false)));
    dbg_log_allocs += 1;
    l.next = null;
    l.n = 0;
    l.seq = 0;
    l.frees = .{};
    return l;
}

fn logCapFollow() void {
    if (log_cap_fixed) return;
    const boost = log_boost.load(.monotonic);
    var cap = c_threshold * LOG_PER_ROOT;
    const b = LOG_MIN * boost;
    if (cap < b) cap = b;
    if (cap > LOG_CAP) cap = LOG_CAP;
    if (c_pure and c_threshold <= c_min_threshold and boost == 1 and log_floor < cap) cap = log_floor;
    log_cap.store(cap, .monotonic);
}

// C adaptive queue depth (was missing: the limit stayed at Q_ADAPT_START). Guarded by mu.
const Q_ADAPT_COOL = 16; // hand-offs between two doublings
const Q_ADAPT_WINDOW = 64;
var q_win: u32 = 0;
var q_win_bad: bool = false;
var q_cool: u32 = 0;
var q_target_ns: i64 = 0;

/// A back-pressure wait `d` longer than the pause target doubles the limit (up to Q_ADAPT_MAX, at most
/// once per Q_ADAPT_COOL hand-offs; at the maximum, logs grow instead via log_boost); a window of
/// Q_ADAPT_WINDOW calm hand-offs (no wait over a quarter of the target, queue never past half the limit)
/// first undoes a boost, then halves the limit (down to Q_ADAPT_MIN). A short queue confirms and returns
/// garbage sooner and keeps fewer logs resident; a long one absorbs collector spikes.
fn queueAdapt(d: i64) void {
    if (q_cool != 0) q_cool -= 1;
    if (d > q_target_ns and q_cool == 0) {
        const boost = log_boost.load(.monotonic);
        if (max_queued >= Q_ADAPT_MAX and !log_cap_fixed and !c_pure and LOG_MIN * boost < LOG_CAP) {
            log_boost.store(boost * 2, .monotonic);
            logCapFollow();
        }
        max_queued = @min(max_queued * 2, Q_ADAPT_MAX);
        q_win = 0;
        q_win_bad = false;
        q_cool = Q_ADAPT_COOL;
    } else if (d > q_target_ns) {
        q_win_bad = true;
    } else {
        if (d > @divTrunc(q_target_ns, 4) or q_len * 2 > max_queued) q_win_bad = true;
        q_win += 1;
        if (q_win >= Q_ADAPT_WINDOW and !q_win_bad and log_boost.load(.monotonic) > 1) {
            log_boost.store(log_boost.load(.monotonic) / 2, .monotonic);
            logCapFollow();
            q_win = 0;
        } else if (q_win >= Q_ADAPT_WINDOW) {
            if (!q_win_bad and max_queued > Q_ADAPT_MIN) max_queued = @max(max_queued / 2, Q_ADAPT_MIN);
            q_win = 0;
            q_win_bad = false;
        }
    }
}

fn handoff() void {
    lock();
    if (!coll_started) {
        coll_started = true;
        const t = std.Thread.spawn(.{}, collectorMain, .{}) catch {
            host.rt_panic("epoch GC: cannot start the collector thread");
        };
        t.detach();
    }
    if (cur) |l| {
        if (l.n != 0 or l.frees.len != 0) {
            handed += 1;
            l.seq = handed;
            if (q_tail) |tail| tail.next = l else q_head = l;
            q_tail = l;
            q_len += 1;
            cur = null;
            signalWork();
        }
    }
    if (max_queued == 0) {
        const qe = host.getenv_i64("KX_GC_MAX_QUEUED", 0);
        if (qe > 0) {
            max_queued = @intCast(qe);
            q_fixed = true;
        } else max_queued = Q_ADAPT_START;
        q_target_ns = host.getenv_i64("KX_GC_TARGET_PAUSE_US", 3000) * 1000;
    }
    var d: i64 = 0;
    if (q_len > max_queued) {
        const w0 = host.rt_nanos();
        while (q_len > max_queued) waitDone();
        d = host.rt_nanos() - w0;
    }
    if (!q_fixed) queueAdapt(d);
    obj.PtrStack.moveFrom(&ret_local, &ret_shared);
    m_applied = applied;
    if (cur == null) cur = logNew();
    unlock();
}

var c_roots = obj.PtrStack{};
var c_work = obj.PtrStack{};
var c_ret = obj.PtrStack{};
var c_deferred = obj.PtrStack{};
var c_live_def = obj.PtrStack{};
var c_dying = obj.PtrStack{};
var c_stable_n: i64 = 0;
var c_releasing: bool = false;
var c_zombies: usize = 0;
var defer_flush: i64 = 8;
var next_set_id: u64 = 1;
var c_major: bool = false;

const Batch = struct {
    next: ?*Batch = null,
    valid_after: u64 = 0,
    first_id: u64 = 0,
    nsets: usize = 0,
    ends: []usize = &.{},
    members: []?*anyopaque = &.{},
};
var cands: ?*Batch = null;
var cands_tail: ?*Batch = null;
var cw_m = obj.PtrStack{};
var cw_ends = obj.PtrStack{};
var cw_first_id: u64 = 0;
var cw_id: u64 = 0;

fn has(p: *anyopaque, bit: u64) bool {
    return (obj.header(p).* & bit) != 0;
}
fn setBit(p: *anyopaque, bit: u64) void {
    obj.header(p).* |= bit;
}
fn clrBit(p: *anyopaque, bit: u64) void {
    obj.header(p).* &= ~bit;
}
fn crcOf(p: *anyopaque) u64 {
    return (obj.header(p).* >> CRC_SHIFT) & CRC_MAX;
}
fn setCrc(p: *anyopaque, v: u64) void {
    obj.header(p).* = (obj.header(p).* & ~CRC_MASK) | ((v & CRC_MAX) << CRC_SHIFT);
}

fn touchKeep(p: *anyopaque) void {
    obj.header(p).* |= DIRTY_BIT;
}
fn touch(p: *anyopaque) void {
    const h = obj.header(p).*;
    if (h & STABLE_BIT != 0) c_stable_n -= 1;
    obj.header(p).* = (h | DIRTY_BIT) & ~STABLE_BIT;
}
fn promote(p: *anyopaque) void {
    if (!has(p, STABLE_BIT)) {
        setBit(p, STABLE_BIT);
        c_stable_n += 1;
    }
}

fn retPush(p: *anyopaque) void {
    c_ret.push(p);
}

fn releaseDeadChild(t: ?*anyopaque) callconv(.c) void {
    if (t) |p| if (isTraced(p)) decApply(p);
}

fn releaseChildren(p: *anyopaque) void {
    c_found += 1;
    if (has(p, STABLE_BIT)) {
        clrBit(p, STABLE_BIT);
        c_stable_n -= 1;
    }
    clrBit(p, DEAD_BIT);
    obj.setColor(p, obj.BLACK);
    c_dying.push(p);
    if (c_releasing) return;
    c_releasing = true;
    const tm = coll_tm;
    const pm = tm.*;
    tm.* = kx.TRAV_RELEASE;
    while (c_dying.len != 0) {
        const x = c_dying.pop().?;
        if (obj.vtab(x).trav) |trav| trav(x, releaseDeadChild);
    }
    tm.* = pm;
    c_releasing = false;
}

fn releaseDead(p: *anyopaque) void {
    retPush(p);
    releaseChildren(p);
}
fn releaseZombie(p: *anyopaque) void {
    c_zombies += 1;
    setBit(p, ZOMBIE_BIT);
    releaseChildren(p);
}

fn possibleRoot(p: *anyopaque) void {
    obj.setColor(p, obj.PURPLE);
    if (!has(p, kx.BUF_BIT)) {
        setBit(p, kx.BUF_BIT);
        c_roots.push(p);
    }
}

fn decApply(p: *anyopaque) void {
    const h = obj.header(p).*;
    if (h & kx.CNT_MASK == 0) host.rt_panic("epoch GC: reference count underflow");
    if ((h & STABLE_BIT) != 0 and (h & kx.CNT_MASK) > 1 and defer_live) {
        obj.header(p).* = (h - 1) | DIRTY_BIT;
        if ((h & (kx.BUF_BIT | CAND_BIT)) == 0) {
            obj.setColor(p, obj.PURPLE);
            setBit(p, kx.BUF_BIT);
            c_live_def.push(p);
        }
        return;
    }
    obj.header(p).* = h - 1;
    touch(p);
    if (obj.refCount(p) == 0) {
        if (has(p, CAND_BIT)) setBit(p, DEAD_BIT) else if (has(p, kx.BUF_BIT)) releaseZombie(p) else releaseDead(p);
    } else possibleRoot(p);
}

fn hintApply(p: *anyopaque) void {
    const h = obj.header(p).*;
    if (h & kx.CNT_MASK == 0) return;
    if ((h & STABLE_BIT) != 0 and defer_live) {
        obj.header(p).* = h | DIRTY_BIT;
        if ((h & (kx.BUF_BIT | CAND_BIT)) == 0) {
            obj.setColor(p, obj.PURPLE);
            setBit(p, kx.BUF_BIT);
            c_live_def.push(p);
        }
        return;
    }
    touch(p);
    possibleRoot(p);
}

fn applyLog(l: *Log) void {
    var nd: usize = 0;
    var i: usize = 0;
    while (i < l.n) : (i += 1) {
        const e = l.a[i];
        const p: *anyopaque = @ptrFromInt(e & ~@as(usize, 3));
        if ((e & 3) == OP_INC) {
            obj.header(p).* = (obj.header(p).* + 1) | DIRTY_BIT;
        } else if ((e & 3) == OP_MOD) {
            touchKeep(p);
        } else {
            l.a[nd] = e;
            nd += 1;
        }
    }
    i = 0;
    while (i < nd) : (i += 1) {
        const e = l.a[i];
        const p: *anyopaque = @ptrFromInt(e & ~@as(usize, 3));
        if ((e & 3) == OP_DEC) decApply(p) else hintApply(p);
    }
}

fn mgChild(t: ?*anyopaque) callconv(.c) void {
    const p = t orelse return;
    if (!isTraced(p)) return;
    var h = obj.header(p).*;
    if (h & (CAND_BIT | DEAD_BIT) != 0) return;
    if (!c_major and (h & STABLE_BIT) != 0) {
        c_hit_stable = true;
        return;
    }
    obj.header(p).* = h + (@as(u64, 1) << CRC_SHIFT);
    h = obj.header(p).*;
    if (((h >> kx.COLOR_SHIFT) & 3) != obj.GRAY) {
        obj.setColor(p, obj.GRAY);
        if ((h >> CRC_SHIFT) & CRC_MAX == 1) clrBit(p, DIRTY_BIT);
        c_work.push(p);
    }
}

fn sbChild(t: ?*anyopaque) callconv(.c) void {
    const p = t orelse return;
    if (!isTraced(p)) return;
    const h = obj.header(p).*;
    if (h & (CAND_BIT | DEAD_BIT) != 0) return;
    if (((h >> kx.COLOR_SHIFT) & 3) != obj.BLACK) {
        obj.setColor(p, obj.BLACK);
        setCrc(p, 0);
        promote(p);
        c_black.push(p);
    }
}

var c_black = obj.PtrStack{};
var c_hit_stable: bool = false;
var c_marked = obj.PtrStack{};

fn scanOne(x: *anyopaque) void {
    const h = obj.header(x).*;
    if (((h >> kx.COLOR_SHIFT) & 3) != obj.GRAY) return;
    const ext: i64 = @as(i64, @intCast(h & kx.CNT_MASK)) - @as(i64, @intCast((h >> CRC_SHIFT) & CRC_MAX));
    if (ext > 0) {
        obj.setColor(x, obj.BLACK);
        setCrc(x, 0);
        promote(x);
        c_black.push(x);
        while (c_black.len != 0) {
            const y = c_black.pop().?;
            if (obj.vtab(y).trav) |trav| trav(y, sbChild);
        }
    } else {
        obj.setColor(x, obj.WHITE);
        if (obj.vtab(x).trav) |trav| trav(x, scanChild);
    }
}

fn scanChild(t: ?*anyopaque) callconv(.c) void {
    if (t) |p| if (isTraced(p) and !has(p, CAND_BIT)) c_work.push(p);
}

fn cwChild(t: ?*anyopaque) callconv(.c) void {
    const p = t orelse return;
    if (!isTraced(p) or has(p, CAND_BIT)) return;
    if (obj.color(p) == obj.WHITE and obj.refCount(p) > 0 and !has(p, DEAD_BIT)) {
        if (has(p, STABLE_BIT)) {
            clrBit(p, STABLE_BIT);
            c_stable_n -= 1;
        }
        setBit(p, CAND_BIT);
        setCrc(p, cw_id & CRC_MAX);
        cw_m.push(p);
        c_work.push(p);
    }
}

fn collectWhite(s: *anyopaque) void {
    if (obj.color(s) != obj.WHITE or has(s, CAND_BIT | DEAD_BIT) or obj.refCount(s) == 0) return;
    if (cw_ends.len == 0) cw_first_id = next_set_id;
    cw_id = next_set_id;
    next_set_id += 1;
    if (has(s, STABLE_BIT)) {
        clrBit(s, STABLE_BIT);
        c_stable_n -= 1;
    }
    setBit(s, CAND_BIT);
    setCrc(s, cw_id & CRC_MAX);
    cw_m.push(s);
    c_work.push(s);
    while (c_work.len != 0) {
        const x = c_work.pop().?;
        if (obj.vtab(x).trav) |trav| trav(x, cwChild);
    }
    cw_ends.push(@ptrFromInt(cw_m.len));
}

var v_sid: u64 = 0;
var v_internal: i64 = 0;
fn inSet(t: *anyopaque) bool {
    return has(t, CAND_BIT) and crcOf(t) == v_sid;
}
fn countChild(t: ?*anyopaque) callconv(.c) void {
    const p = t orelse return;
    if (isTraced(p) and inSet(p)) v_internal += 1;
}
fn freeCycleChild(t: ?*anyopaque) callconv(.c) void {
    if (t) |p| if (isTraced(p) and !inSet(p)) decApply(p);
}

fn closeSets() void {
    var start: usize = 0;
    var s: usize = 0;
    while (s < cw_ends.len) : (s += 1) {
        const end = @intFromPtr(cw_ends.at(s));
        var sum: i64 = 0;
        v_sid = (cw_first_id + s) & CRC_MAX;
        v_internal = 0;
        var i = start;
        while (i < end) : (i += 1) {
            const x = cw_m.at(i).?;
            sum += @intCast(obj.refCount(x));
            if (obj.vtab(x).trav) |trav| trav(x, countChild);
        }
        if (sum != v_internal) touchKeep(cw_m.at(start).?);
        start = end;
    }
    lock();
    const h = handed;
    unlock();
    if (cw_ends.len == 0) return;
    const n = cw_m.len;
    const k = cw_ends.len;
    c_found += @intCast(n);
    const b: *Batch = @ptrCast(@alignCast(host.malloc(@sizeOf(Batch))));
    const mem: [*]?*anyopaque = @ptrCast(@alignCast(host.malloc(n * @sizeOf(?*anyopaque))));
    const ends: [*]usize = @ptrCast(@alignCast(host.malloc(k * @sizeOf(usize))));
    var i: usize = 0;
    while (i < n) : (i += 1) mem[i] = cw_m.at(i);
    i = 0;
    while (i < k) : (i += 1) ends[i] = @intFromPtr(cw_ends.at(i));
    b.* = .{ .valid_after = h, .first_id = cw_first_id, .nsets = k, .ends = ends[0..k], .members = mem[0..n] };
    if (cands_tail) |t| t.next = b else cands = b;
    cands_tail = b;
    cw_m.len = 0;
    cw_ends.len = 0;
}

fn validate(id: u64, members: []?*anyopaque) usize {
    var ok = true;
    v_sid = id & CRC_MAX;
    for (members) |m| {
        if (obj.header(m.?).* & (DIRTY_BIT | DEAD_BIT) != 0) {
            ok = false;
            break;
        }
    }
    if (ok) {
        const tm = coll_tm;
        const pm = tm.*;
        tm.* = kx.TRAV_RELEASE;
        for (members) |m| if (obj.vtab(m.?).trav) |trav| trav(m.?, freeCycleChild);
        tm.* = pm;
        for (members) |mm| {
            const x = mm.?;
            clrBit(x, CAND_BIT);
            obj.setColor(x, obj.BLACK);
            setCrc(x, 0);
            obj.header(x).* &= ~kx.CNT_MASK;
            if (has(x, kx.BUF_BIT)) setBit(x, ZOMBIE_BIT) else retPush(x);
        }
        return members.len;
    }
    for (members) |mm| {
        const x = mm.?;
        clrBit(x, CAND_BIT);
        obj.setColor(x, obj.BLACK);
        setCrc(x, 0);
        if (has(x, DEAD_BIT)) {
            if (has(x, kx.BUF_BIT)) releaseZombie(x) else releaseDead(x);
        } else if (obj.refCount(x) > 0) possibleRoot(x);
    }
    return 0;
}

fn validateReady(upto: u64, force: bool) usize {
    var freed: usize = 0;
    while (cands) |b| {
        if (!force and b.valid_after >= upto) break;
        cands = b.next;
        if (cands == null) cands_tail = null;
        var start: usize = 0;
        var i: usize = 0;
        while (i < b.nsets) : (i += 1) {
            freed += validate(b.first_id + i, b.members[start..b.ends[i]]);
            start = b.ends[i];
        }
        host.free(@ptrCast(b.members.ptr));
        host.free(@ptrCast(b.ends.ptr));
        host.free(@ptrCast(b));
    }
    return freed;
}

fn detectPrepare(major: bool) obj.PtrStack {
    c_major = major;
    if (major) obj.PtrStack.moveFrom(&c_deferred, &c_live_def);
    if (major) obj.PtrStack.moveFrom(&c_roots, &c_deferred);
    var roots = c_roots;
    c_roots = .{};
    var i: usize = 0;
    while (i < roots.len) : (i += 1) {
        const s = roots.at(i).?;
        clrBit(s, kx.BUF_BIT);
        if (has(s, ZOMBIE_BIT)) {
            clrBit(s, ZOMBIE_BIT);
            retPush(s);
            roots.set(i, null);
            continue;
        }
        if (has(s, DEAD_BIT) and !has(s, CAND_BIT)) {
            clrBit(s, DEAD_BIT);
            releaseDead(s);
            roots.set(i, null);
        }
    }
    var k: usize = 0;
    i = 0;
    while (i < roots.len) : (i += 1) {
        const s = roots.at(i) orelse continue;
        if (has(s, CAND_BIT | DEAD_BIT)) continue;
        if (obj.refCount(s) > 0) {
            obj.setColor(s, obj.GRAY);
            setCrc(s, 0);
            clrBit(s, DIRTY_BIT);
            roots.set(k, s);
            k += 1;
        }
    }
    roots.len = k;
    return roots;
}

fn settle(x: *anyopaque) void {
    if (has(x, CAND_BIT)) return;
    if (obj.color(x) == obj.GRAY or obj.color(x) == obj.WHITE) obj.setColor(x, obj.BLACK);
    setCrc(x, 0);
}

fn detect(major: bool) void {
    var roots = detectPrepare(major);
    c_hit_stable = false;
    var i: usize = 0;
    while (i < roots.len) : (i += 1) {
        const r = roots.at(i).?;
        c_work.push(r);
        c_marked.push(r);
    }
    var visits: i64 = 0;
    while (c_work.len != 0) {
        const x = c_work.pop().?;
        visits += 1;
        if (obj.vtab(x).trav) |trav| trav(x, mgChild);
    }
    c_traversed += visits;
    i = 0;
    while (i < roots.len) : (i += 1) c_work.push(roots.at(i).?);
    while (c_work.len != 0) scanOne(c_work.pop().?);
    i = 0;
    while (i < roots.len) : (i += 1) collectWhite(roots.at(i).?);
    i = 0;
    while (i < c_marked.len) : (i += 1) settle(c_marked.at(i).?);
    c_marked.len = 0;
    if (!major and c_hit_stable) {
        i = 0;
        while (i < roots.len) : (i += 1) {
            const s = roots.at(i).?;
            if (!has(s, CAND_BIT) and !has(s, kx.BUF_BIT)) {
                setBit(s, kx.BUF_BIT);
                c_deferred.push(s);
            }
        }
    }
    roots.deinit();
    closeSets();
}

fn flushLiveDef() void {
    c_after_flush = true;
    var i: usize = 0;
    while (i < c_live_def.len) : (i += 1) {
        const s = c_live_def.at(i).?;
        if (has(s, ZOMBIE_BIT)) {
            clrBit(s, ZOMBIE_BIT);
            clrBit(s, kx.BUF_BIT);
            retPush(s);
            continue;
        }
        if (has(s, STABLE_BIT)) {
            clrBit(s, STABLE_BIT);
            c_stable_n -= 1;
        }
        c_roots.push(s);
    }
    c_live_def.len = 0;
    c_zombies = 0;
}

fn fullCycle() void {
    while (true) {
        var freed = validateReady(0, true);
        if (c_roots.len != 0 or c_deferred.len != 0 or c_live_def.len != 0) {
            detect(true);
            freed += validateReady(0, true);
        }
        gc_st.reclaimed += @intCast(freed);
        if (freed == 0 and c_roots.len == 0 and c_deferred.len == 0 and c_live_def.len == 0 and cands == null) break;
    }
}

fn publishReturns() void {
    if (c_ret.len == 0) return;
    lock();
    obj.PtrStack.moveFrom(&ret_shared, &c_ret);
    unlock();
}

const MAJOR_RATIO_MAX: i64 = 256;
const DEFER_FLUSH_BASE: i64 = 8;
const DEFER_FLUSH_MAX: usize = 65536;
const PURE_STABLE_MAX: i64 = 65536;
var major_ratio: i64 = MAJOR_RATIO;
var c_after_flush: bool = false;
/// Objects visited by MarkGray / found dead or in candidate sets (C c_traversed, dbg_dead + dbg_members).
var c_traversed: i64 = 0;
var c_found: i64 = 0;

/// One detection plus the C adaptive rules (collector_main), which the port had dropped:
/// a minor whose trace was mostly live data doubles the root threshold (and with it the log
/// size); a productive one halves it back; majors and live-root flushes back off the same way.
fn detectAdaptive(major: bool) void {
    const nroots: i64 = @intCast(c_roots.len);
    const m0 = c_found;
    const w0 = c_traversed;
    detect(major);
    gc_st.collections += 1;
    const found = c_found - m0;
    const work = c_traversed - w0;
    if (major) {
        if (work > 64 * found) {
            if (major_ratio < MAJOR_RATIO_MAX) major_ratio *= 2;
        } else major_ratio = MAJOR_RATIO;
    } else if (work > 4 * found + 2 * nroots) {
        if (c_threshold < C_MAX_THRESHOLD) c_threshold *= 2;
    } else if (c_threshold > c_min_threshold) {
        c_threshold = @max(c_threshold / 2, c_min_threshold);
    }
    if (!major and c_after_flush) {
        c_after_flush = false;
        if (work > 64 * found) {
            if (defer_flush < 4096) defer_flush *= 2;
        } else defer_flush = DEFER_FLUSH_BASE;
    }
    if (!major) c_pure = found > 0 and work <= found and c_stable_n < PURE_STABLE_MAX;
    logCapFollow();
}

fn sweepList(st: *obj.PtrStack) void {
    var k: usize = 0;
    var i: usize = 0;
    while (i < st.len) : (i += 1) {
        const s = st.at(i).?;
        if (has(s, ZOMBIE_BIT)) {
            clrBit(s, ZOMBIE_BIT);
            clrBit(s, kx.BUF_BIT);
            retPush(s);
        } else {
            st.set(k, s);
            k += 1;
        }
    }
    st.len = k;
}

/// C sweep_deferred: deferred live roots wait for a major, and those that die meanwhile (lru:
/// evicted entries) are zombies whose memory would wait too; once most of the deferred lists are
/// zombies, return their memory now. Missing from the port: zombie memory waited for a major.
fn sweepDeferred() void {
    sweepList(&c_live_def);
    sweepList(&c_deferred);
    c_zombies = 0;
}

/// The collector thread's own `rt_trav_mode` (thread-local in the runtime). Taken once:
/// on Darwin every thread-local access is a `_tlv_get_addr` call (~8% of collector time
/// when it was read and written around each dead object).
var coll_tm: *c_int = undefined;

fn collectorMain() void {
    coll_tm = &host.rt_trav_mode;
    lock();
    while (true) {
        while (q_head == null and !full_req and !shutting) waitWork();
        if (q_head) |l| {
            q_head = l.next;
            if (q_head == null) q_tail = null;
            q_len -= 1;
            broadcastDone();
            unlock();
            var i: usize = 0;
            while (i < l.frees.len) : (i += 1) host.free(l.frees.at(i));
            l.frees.len = 0;
            applyLog(l);
            if (c_live_def.len >= 4096 and (@as(i64, @intCast(c_live_def.len)) * defer_flush >= c_stable_n or c_live_def.len >= DEFER_FLUSH_MAX)) {
                flushLiveDef();
            } else if (c_zombies >= 4096 and c_zombies * 2 >= c_live_def.len + c_deferred.len) {
                sweepDeferred();
            }
            const freed = validateReady(l.seq, false);
            const major_at = major_ratio * @max(c_stable_n, @as(i64, @intCast(c_threshold)));
            if (c_roots.len >= c_threshold or @as(i64, @intCast(c_deferred.len)) >= major_at) {
                const major = @as(i64, @intCast(c_deferred.len)) >= major_at;
                detectAdaptive(major);
            }
            gc_st.reclaimed += @intCast(freed);
            publishReturns();
            lock();
            applied = l.seq;
            // keep only as many spare logs as the queue may hold again; return the rest after a spike
            if (pool_len > max_queued + 2) {
                l.frees.deinit();
                _ = libc_mm.munmap(@ptrCast(l), @sizeOf(Log));
            } else {
                l.next = log_pool;
                log_pool = l;
                pool_len += 1;
            }
            broadcastDone();
        } else if (full_req) {
            unlock();
            fullCycle();
            publishReturns();
            lock();
            full_req = false;
            full_done += 1;
            broadcastDone();
        } else break;
    }
    unlock();
}

fn mutReleaseChild(t: ?*anyopaque) callconv(.c) void {
    if (t) |p| if (!isTraced(p)) if (obj.vtab(p).rel) |rel| rel(p);
}

/// Dead owners of collections (`rt_relo_owner`) with the sequence number of the log that must be
/// applied before their memory can go: OWNER_MOD and rt_gc_root_hint reach an owner through the
/// collection, not through a counted reference, so entries naming it can be logged after it died, up
/// to its relo. Pairs (object, seq). C `m_held` / `free_held`.
var m_held = obj.PtrStack{};

fn freeHeld(all: bool) void {
    var k: usize = 0;
    var i: usize = 0;
    while (i < m_held.len) : (i += 2) {
        const p = m_held.at(i).?;
        const seq: u64 = @intFromPtr(m_held.at(i + 1));
        if (all or seq <= m_applied) {
            obj.vtab(p).freemem.?(p);
        } else {
            m_held.set(k, p);
            m_held.set(k + 1, m_held.at(i + 1));
            k += 2;
        }
    }
    m_held.len = k;
}

/// `tm` is the calling (mutator) thread's `rt_trav_mode`, looked up once per batch.
inline fn freeReturned(p: *anyopaque, tm: *c_int) void {
    // C free_returned: one vtab load, unconditional trav/relo/freemem calls.
    const vt = obj.vtab(p);
    tm.* = kx.TRAV_FREE;
    vt.trav.?(p, mutReleaseChild);
    tm.* = kx.TRAV_SCAN;
    host.rt_relo_owner = 0;
    vt.relo.?(p);
    if (host.rt_relo_owner == 0) {
        vt.freemem.?(p);
        return;
    }
    // Was leaked before: the owner's memory is held until every log that may still name it is
    // applied (entries logged up to now are in the current log, handed next, or in a handed one).
    m_held.push(p);
    m_held.push(@ptrFromInt(if (cur != null and cur.?.n != 0) handed + 1 else handed));
}

fn processReturns() void {
    if (m_held.len != 0) freeHeld(false);
    const tm = &host.rt_trav_mode;
    while (ret_pos < ret_local.len) {
        freeReturned(ret_local.at(ret_pos).?, tm);
        ret_pos += 1;
    }
    ret_local.len = 0;
    ret_pos = 0;
}

// C free_returned stays out of line. Inlining the paced loop into allocTrace
// made newObj too fat for op_alloc (no-LTO `call newObj` every iteration).
noinline fn freePaced() void {
    if (ret_pos >= ret_local.len) return;
    const back = ret_local.len - ret_pos;
    var k: usize = if (back > 65536) 16 else if (back > 16384) 8 else if (back > 4096) 4 else 2;
    const tm = &host.rt_trav_mode;
    while (k > 0 and ret_pos < ret_local.len) : (k -= 1) {
        freeReturned(ret_local.at(ret_pos).?, tm);
        ret_pos += 1;
    }
    if (ret_pos == ret_local.len) {
        ret_local.len = 0;
        ret_pos = 0;
    }
}

// C: `__attribute__((noinline)) void log_first` so log_op has no stack frame.
noinline fn logFirst() void {
    const e = std.c.getenv("KX_GC_LOG_CAP");
    if (e != null and e.?[0] != 0) {
        var cap: usize = @intCast(host.getenv_i64("KX_GC_LOG_CAP", 512));
        if (cap > LOG_CAP) cap = LOG_CAP;
        log_cap.store(cap, .monotonic);
        log_cap_fixed = true;
    } else logCapFollow();
    lock();
    cur = logNew();
    unlock();
}

inline fn logOp(e: usize) void {
    // C log_op: `if (cur == NULL) log_first(); cur->a[cur->n++] = e; if (n >= cap) boundary();`
    if (cur == null) {
        @branchHint(.unlikely);
        logFirst();
    }
    const l = cur.?;
    const n = l.n;
    l.a[n] = e;
    const n1 = n + 1;
    l.n = n1;
    if (n1 >= log_lim) {
        @branchHint(.unlikely);
        boundary();
    }
}

/// Always-inline mutator API (C `always_inline` log_op / rt_gc_log_*). Export
/// wrappers stay for the C ABI; native ops must call these so Darwin (no LTO)
/// still inlines the log into the mutator.
pub inline fn logInc(p: ?*anyopaque) void {
    if (p) |q| logOp(@intFromPtr(q) | OP_INC);
}
pub inline fn logDec(p: ?*anyopaque) void {
    if (p) |q| logOp(@intFromPtr(q) | OP_DEC);
}
pub inline fn writeBarrier(o: ?*anyopaque) void {
    logOp(@intFromPtr(o) | OP_MOD);
}

// Out of line like C: inlining this into log_op gives every retain/store a fat frame.
noinline fn boundary() void {
    if (in_boundary) {
        lock();
        handed += 1;
        cur.?.seq = handed;
        if (q_tail) |t| t.next = cur else q_head = cur;
        q_tail = cur;
        q_len += 1;
        cur = null;
        signalWork();
        cur = logNew();
        unlock();
        return;
    }
    in_boundary = true;
    const t0 = host.rt_nanos();
    handoff();
    processReturns();
    slabFlush();
    obj.statsAddPause(&gc_st, host.rt_nanos() - t0);
    in_boundary = false;
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
    logOp(@intFromPtr(p) | OP_ROOT);
}
pub export fn rt_gc_free_later(p: ?*anyopaque) void {
    const q = p orelse return;
    if (cur == null) {
        host.free(q);
        return;
    }
    cur.?.frees.push(q);
}

fn exitDrain() bool {
    return host.getenv_present("KX_GC_EXIT_DRAIN") or host.getenv_present("KX_GC_STATS");
}

pub export fn rt_gc_collect() void {
    if (in_boundary) return;
    // Tests and leak-check need a drain; standalone benches set KX_GC_STATS or KX_GC_EXIT_DRAIN.
    // Default C skips drain unless leak-check / malloc / EXIT_DRAIN. Native tests always drain.
    in_boundary = true;
    const t0 = host.rt_nanos();
    while (true) {
        const had = cur != null and (cur.?.n != 0 or cur.?.frees.len != 0);
        handoff();
        lock();
        while (q_head != null) waitDone();
        const want = full_done + 1;
        full_req = true;
        signalWork();
        while (full_done < want) waitDone();
        obj.PtrStack.moveFrom(&ret_local, &ret_shared);
        m_applied = applied;
        unlock();
        const returned = ret_local.len - ret_pos;
        processReturns();
        if (!had and returned == 0 and !(cur != null and (cur.?.n != 0 or cur.?.frees.len != 0))) break;
    }
    freeHeld(true); // the queue is empty and every handed log applied
    obj.statsAddPause(&gc_st, host.rt_nanos() - t0);
    in_boundary = false;
}

pub export fn rt_gc_name() [*:0]const u8 {
    return "epoch";
}
pub export fn rt_gc_stats(out: *kx.Stats) void {
    lock();
    out.* = gc_st;
    if (host.getenv_present("KX_GC_DEBUG")) epochDebug();
    unlock();
}

fn epochDebug() void {
    const mib = 1.0 / 1048576.0;
    _ = std.c.printf("epoch: mem MiB slabs=%.2f logs=%lld(%.2f) stacks(cap) roots=%.2f deferred=%.2f live_def=%.2f work=%.2f black=%.2f marked=%.2f ret=%.2f ret-shared=%.2f ret-local=%.2f cw=%.2f dying=%.2f\n", @as(f64, @floatFromInt(dbg_slab_bytes)) * mib, @as(c_longlong, dbg_log_allocs), @as(f64, @floatFromInt(dbg_log_allocs * @sizeOf(Log))) * mib, capMib(&c_roots), capMib(&c_deferred), capMib(&c_live_def), capMib(&c_work), capMib(&c_black), capMib(&c_marked), capMib(&c_ret), capMib(&ret_shared), capMib(&ret_local), capMib(&cw_m) + capMib(&cw_ends), capMib(&c_dying));
    _ = std.c.printf("epoch: threshold=%zu log_cap=%zu stable=%lld collections=%lld logs_handed=%llu alloc_cuts=%lld max_queued=%zu\n", c_threshold, log_cap.load(.monotonic), @as(c_longlong, c_stable_n), @as(c_longlong, gc_st.collections), @as(c_ulonglong, handed), @as(c_longlong, dbg_alloc_cuts), max_queued);
}
var dbg_alloc_cuts: i64 = 0;
fn capMib(s: *const obj.PtrStack) f64 {
    return @as(f64, @floatFromInt(s.cap * 8)) / 1048576.0;
}
var dbg_slab_bytes: i64 = 0;
var dbg_log_allocs: i64 = 0;

