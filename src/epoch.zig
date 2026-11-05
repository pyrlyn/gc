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

fn slabOf(p: *anyopaque) ?*Slab {
    const pg = @intFromPtr(p) >> PAGE_SHIFT;
    const d = slab_dir[pg >> 16] orelse return null;
    return d[pg & 0xffff];
}

fn slabNew() *Slab {
    const base: [*]u8 = @ptrCast(pageAlloc(PAGE));
    const pg = @intFromPtr(base) >> PAGE_SHIFT;
    var d = slab_dir[pg >> 16];
    if (d == null) {
        const raw = host.calloc((1 << 16) * @sizeOf(?*Slab));
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

fn slabRefill(cls: usize) *anyopaque {
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

fn slabAlloc(cls: usize) *anyopaque {
    if (slab_cur[cls]) |s| {
        if (s.free) |free_cell| {
            const next: *?*anyopaque = @ptrCast(@alignCast(free_cell));
            s.free = next.*;
            s.live += 1;
            return free_cell;
        }
        if (@intFromPtr(s.bump) + (cls << 3) <= @intFromPtr(s.base) + PAGE) {
            const p: *anyopaque = @ptrCast(s.bump);
            s.bump += cls << 3;
            s.live += 1;
            return p;
        }
    }
    return slabRefill(cls);
}

fn slabFree(p: *anyopaque, cls: usize) void {
    const s = slabOf(p) orelse return;
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
var t_allocs: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var t_frees: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

pub export fn rt_alloc(size: i64) ?*anyopaque {
    return host.malloc(@intCast(size));
}
pub export fn rt_free(p: ?*anyopaque, size: i64) void {
    _ = size;
    host.free(p);
}
pub export fn rt_gc_mem_alloc(n: usize) ?*anyopaque {
    if (n == 0) return host.malloc(0);
    return host.malloc(n);
}
pub export fn rt_gc_mem_calloc(n: usize) ?*anyopaque {
    return host.calloc(n);
}
pub export fn rt_gc_mem_realloc(p: ?*anyopaque, n: usize) ?*anyopaque {
    return host.realloc(p, n);
}
pub export fn rt_gc_mem_free(p: ?*anyopaque) void {
    host.free(p);
}

var big_madvise: i32 = -1;
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

pub export fn rt_alloc_trace(size: i64) ?*anyopaque {
    _ = t_allocs.fetchAdd(1, .monotonic);
    freePaced();
    const cls = (@as(usize, @intCast(size)) + 7) >> 3;
    if (cls > CLASSES) {
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
    if (slab_release < 0) {
        const e = std.c.getenv("KX_GC_SLAB_RELEASE");
        slab_release = if (e != null and e.?[0] == '0') 0 else 1;
    }
    if (slab_release != 0) return slabAlloc(cls);
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

pub export fn rt_free_trace(p: ?*anyopaque, size: i64) void {
    _ = t_frees.fetchAdd(1, .monotonic);
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

fn logNew() *Log {
    if (log_pool) |l| {
        log_pool = l.next;
        l.n = 0;
        l.next = null;
        l.frees.len = 0;
        return l;
    }
    const l: *Log = @ptrCast(@alignCast(host.malloc(@sizeOf(Log))));
    l.* = .{};
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
        const e = std.c.getenv("KX_GC_MAX_QUEUED");
        if (e != null and e.?[0] != 0) {
            max_queued = @intCast(host.getenv_i64("KX_GC_MAX_QUEUED", Q_ADAPT_START));
            q_fixed = true;
        } else max_queued = Q_ADAPT_START;
    }
    while (q_len > max_queued) waitDone();
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
    if (has(p, STABLE_BIT)) {
        clrBit(p, STABLE_BIT);
        c_stable_n -= 1;
    }
    clrBit(p, DEAD_BIT);
    obj.setColor(p, obj.BLACK);
    c_dying.push(p);
    if (c_releasing) return;
    c_releasing = true;
    const pm = host.rt_trav_mode;
    host.rt_trav_mode = kx.TRAV_RELEASE;
    while (c_dying.len != 0) {
        const x = c_dying.pop().?;
        if (obj.vtab(x).trav) |trav| trav(x, releaseDeadChild);
    }
    host.rt_trav_mode = pm;
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
        const pm = host.rt_trav_mode;
        host.rt_trav_mode = kx.TRAV_RELEASE;
        for (members) |m| if (obj.vtab(m.?).trav) |trav| trav(m.?, freeCycleChild);
        host.rt_trav_mode = pm;
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
    while (c_work.len != 0) {
        const x = c_work.pop().?;
        if (obj.vtab(x).trav) |trav| trav(x, mgChild);
    }
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

fn collectorMain() void {
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
            if (c_live_def.len >= 4096 and (@as(i64, @intCast(c_live_def.len)) * defer_flush >= c_stable_n or c_live_def.len >= 65536)) flushLiveDef();
            const freed = validateReady(l.seq, false);
            const major_at = MAJOR_RATIO * @max(c_stable_n, @as(i64, @intCast(c_threshold)));
            if (c_roots.len >= c_threshold or @as(i64, @intCast(c_deferred.len)) >= major_at) {
                const major = @as(i64, @intCast(c_deferred.len)) >= major_at;
                detect(major);
                gc_st.collections += 1;
            }
            gc_st.reclaimed += @intCast(freed);
            publishReturns();
            lock();
            applied = l.seq;
            l.next = log_pool;
            log_pool = l;
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

fn freeReturned(p: *anyopaque) void {
    host.rt_trav_mode = kx.TRAV_FREE;
    if (obj.vtab(p).trav) |trav| trav(p, mutReleaseChild);
    host.rt_trav_mode = kx.TRAV_SCAN;
    host.rt_relo_owner = 0;
    if (obj.vtab(p).relo) |relo| relo(p);
    if (host.rt_relo_owner == 0) {
        if (obj.vtab(p).freemem) |f| f(p);
    }
}

fn processReturns() void {
    while (ret_pos < ret_local.len) {
        freeReturned(ret_local.at(ret_pos).?);
        ret_pos += 1;
    }
    ret_local.len = 0;
    ret_pos = 0;
}

fn freePaced() void {
    if (ret_pos >= ret_local.len) return;
    const back = ret_local.len - ret_pos;
    var k: usize = if (back > 65536) 16 else if (back > 16384) 8 else if (back > 4096) 4 else 2;
    while (k > 0 and ret_pos < ret_local.len) : (k -= 1) {
        freeReturned(ret_local.at(ret_pos).?);
        ret_pos += 1;
    }
    if (ret_pos == ret_local.len) {
        ret_local.len = 0;
        ret_pos = 0;
    }
}

fn logFirst() void {
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
    if (cur == null) logFirst();
    const l = cur.?;
    l.a[l.n] = e;
    l.n += 1;
    if (l.n >= log_cap.load(.monotonic)) boundary();
}

fn boundary() void {
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
    if (p) |q| logOp(@intFromPtr(q) | OP_INC);
}
pub export fn rt_gc_log_dec(p: ?*anyopaque) void {
    if (p) |q| logOp(@intFromPtr(q) | OP_DEC);
}
pub export fn rt_gc_write_barrier(o: ?*anyopaque) void {
    logOp(@intFromPtr(o) | OP_MOD);
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
    obj.statsAddPause(&gc_st, host.rt_nanos() - t0);
    in_boundary = false;
}

pub export fn rt_gc_name() [*:0]const u8 {
    return "epoch";
}
pub export fn rt_gc_stats(out: *kx.Stats) void {
    lock();
    out.* = gc_st;
    unlock();
}

