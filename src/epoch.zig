//! Epoch collector: deferred RC + concurrent cycle collection.
//! Port of `epoch/gc.c` (Bacon & Rajan concurrent trial deletion). Parallel
//! MarkGray/Scan helpers, incremental major, side-minor and early-validation
//! are implemented on one collector thread (equivalent to KX_GC_THREADS=1 /
//! KX_GC_INC_MAJOR=0). Semantics of logs, CRC trial deletion, Sigma/Delta,
//! generations, return-to-mutator and exit drain match the C.
//!
//! Where it differs from C (docs/zig-port.md): the collector never makes the mutator wait for a
//! whole cascade or detection. Its long loops look at the queue every `POLL_STEPS` steps (`poll`),
//! hand over what they have released and apply one queued log in the middle of their own work.
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
// Keep at least sixteen objects in a 64 KiB slab. Previously every object
// above 256 bytes took a whole 64 KiB block, including ordinary 512-byte nodes.
// Preserve 8-byte classes through 256 bytes; use 64-byte steps above that to
// keep the hot allocator tables small (92 classes rather than 512).
const SMALL_CLASSES = 32;
const SMALL_MAX = SMALL_CLASSES * 8;
const MEDIUM_SHIFT = 6;
const MEDIUM_QUANTUM = 1 << MEDIUM_SHIFT;
const CLASSES = SMALL_CLASSES + (PAGE / 16 - SMALL_MAX) / MEDIUM_QUANTUM;

inline fn sizeClass(size: i64) usize {
    const n: usize = @intCast(size);
    if (n <= SMALL_MAX) return (n + 7) >> 3;
    return SMALL_CLASSES + ((n - SMALL_MAX + MEDIUM_QUANTUM - 1) >> MEDIUM_SHIFT);
}

inline fn classBytes(cls: usize) usize {
    if (cls <= SMALL_CLASSES) return cls << 3;
    return SMALL_MAX + ((cls - SMALL_CLASSES) << MEDIUM_SHIFT);
}
// Entries in the largest log (64 KiB). It was 32768: a program whose detections find nothing raises
// the root threshold and the log size with it, and six 256 KiB logs in flight were 1.5 MiB resident
// (ops: 10.0 MiB peak against 7.5 at 8192 and 6.5 at 2048) with no gain in speed, and a boundary's
// p99 grew from 12 to 33 us with the log it hands over.
const LOG_CAP = 8192;
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
/// Among the detection's roots or in `c_marked`: the detection in progress holds the object. Logs are applied while it runs
/// (`poll`), so such an object can die under it; its memory then waits for `settle`.
const MARKED_BIT: u64 = 1 << 63;

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
/// Emptied slabs one boundary hands to the pool: each may cost an madvise call (a few microseconds),
/// and a mass death empties hundreds at once. The rest stay in `slab_pending`, where `slabRefill`
/// takes them from.
const SLAB_FLUSH_MAX: usize = 64;

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
var slab_partial: [CLASSES + 1]?*Slab = @splat(null);
var slab_pool: ?*Slab = null;
var slab_pending = obj.PtrStack{};
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

/// An empty slab for any class: one emptied since the last boundary (still resident; C leaves these
/// to `slab_flush`, so a program that frees between boundaries mapped new slabs next to empty
/// ones), else one from the pool.
fn slabTakeEmpty() ?*Slab {
    var s: *Slab = undefined;
    if (slab_pending.len != 0) {
        // Pushed with no live cell, neither current nor in a partial list: unreachable since.
        s = @ptrCast(@alignCast(slab_pending.pop().?));
        std.debug.assert(s.live == 0 and s.in_partial == 0 and s != mut.slab_cur[s.cls]);
    } else if (slab_pool) |pooled| {
        slab_pool = pooled.next;
        if (pooled.resident != 0) slab_pool_resident -= 1;
        s = pooled;
    } else return null;
    s.next = null;
    s.resident = 1;
    s.free = null;
    s.bump = s.base;
    s.live = 0;
    return s;
}

// C: `__attribute__((noinline)) void *slab_refill` — keep the slab_alloc hot path small.
noinline fn slabRefill(cls: usize) *anyopaque {
    var s = slab_partial[cls];
    if (s) |taken| {
        partialUnlink(taken, cls);
    } else if (slabTakeEmpty()) |empty| {
        s = empty;
    } else {
        const fresh = slabNew();
        fresh.bump = fresh.base;
        s = fresh;
    }
    const slab = s.?;
    slab.cls = @intCast(cls);
    mut.slab_cur[cls] = slab;
    var p: *anyopaque = undefined;
    if (slab.free) |free_cell| {
        p = free_cell;
        const next: *?*anyopaque = @ptrCast(@alignCast(free_cell));
        slab.free = next.*;
    } else {
        p = @ptrCast(slab.bump);
        slab.bump += classBytes(cls);
    }
    slab.live += 1;
    return p;
}

inline fn slabAlloc(cls: usize) *anyopaque {
    // C slab_alloc: likely current slab, free-list then bump, else noinline refill.
    const s = mut.slab_cur[cls];
    if (s != null) {
        @branchHint(.likely);
        const slab = s.?;
        if (slab.free) |free_cell| {
            const next: *?*anyopaque = @ptrCast(@alignCast(free_cell));
            slab.free = next.*;
            slab.live += 1;
            return free_cell;
        }
        const next_bump = slab.bump + classBytes(cls);
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
    if (s == mut.slab_cur[cls]) {
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
    // The newest SLAB_FLUSH_MAX; `batch[0..n)` collects those to give back to the system.
    const take = @min(slab_pending.len, SLAB_FLUSH_MAX);
    const batch = slab_pending.items[slab_pending.len - take .. slab_pending.len];
    var n: usize = 0;
    for (batch) |entry| {
        const s: *Slab = @ptrCast(@alignCast(entry.?));
        s.next = slab_pool;
        slab_pool = s;
        if (slab_pool_resident < slab_keep) {
            slab_pool_resident += 1;
            continue;
        }
        s.resident = 0;
        batch[n] = s;
        n += 1;
    }
    if (n > 1) std.mem.sort(?*anyopaque, batch[0..n], {}, slabCmp);
    var i: usize = 0;
    while (i < n) {
        var j = i + 1;
        while (j < n) {
            const prev: *Slab = @ptrCast(@alignCast(batch[j - 1].?));
            const nxt: *Slab = @ptrCast(@alignCast(batch[j].?));
            if (@intFromPtr(nxt.base) != @intFromPtr(prev.base) + PAGE) break;
            j += 1;
        }
        const from: *Slab = @ptrCast(@alignCast(batch[i].?));
        madv(@ptrCast(from.base), (j - i) * PAGE);
        i = j;
    }
    slab_pending.len -= take;
}

const Big = extern struct { next: ?*Big, size: usize };
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
    mut.slab_release = if (e != null and e.?[0] == '0') 0 else 1;
}

noinline fn allocNoSlab(cls: usize) *anyopaque {
    if (mut.free_list[cls]) |p| {
        const next: *?*anyopaque = @ptrCast(@alignCast(p));
        mut.free_list[cls] = next.*;
        return p;
    }
    const need = classBytes(cls);
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
    if (mut.ret_local.head != null) freePaced();
    mut.alloc_left -%= 1;
    if (mut.alloc_left == 0) {
        @branchHint(.unlikely);
        allocCut();
    }
    const cls = sizeClass(size);
    if (cls > CLASSES) {
        @branchHint(.unlikely);
        return allocBig(size);
    }
    if (mut.slab_release < 0) {
        @branchHint(.unlikely);
        initSlabRelease();
    }
    if (mut.slab_release != 0) return slabAlloc(cls);
    return allocNoSlab(cls);
}

pub export fn rt_alloc_trace(size: i64) ?*anyopaque {
    return allocTrace(size);
}

pub inline fn freeTrace(p: ?*anyopaque, size: i64) void {
    const q = p orelse return;
    const cls = sizeClass(size);
    if (cls > CLASSES) {
        const bytes = (@as(usize, @intCast(size)) + PAGE - 1) & ~@as(usize, PAGE - 1);
        const b: *Big = @ptrCast(@alignCast(q));
        b.size = bytes;
        b.next = big_free;
        big_free = b;
        bigRelease(q, bytes);
        return;
    }
    if (mut.slab_release > 0) {
        slabFree(q, cls);
        return;
    }
    const next: *?*anyopaque = @ptrCast(@alignCast(q));
    next.* = mut.free_list[cls];
    mut.free_list[cls] = q;
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
/// What the mutator reads or writes at every allocation and every logged operation, on cache lines
/// of its own. As separate globals these were laid out between the collector's counters and stacks,
/// which it writes for every object: depending on where the linker put them, alloc_drop cost 10 or
/// 13 ns per object (false sharing).
const Mutator = struct {
    cur: ?*Log align(std.atomic.cache_line) = null,
    /// Entry limit of `cur`: log_cap when the log was started, lowered by allocCut.
    log_lim: usize = 0,
    /// Traced allocations a log may still make before allocCut ends it.
    alloc_left: usize = ALLOC_CUT,
    ret_local: RetList = .{},
    /// Objects of `ret_local.head` already taken.
    ret_pos: usize = 0,
    in_boundary: bool = false,
    slab_release: i32 = -1,
    slab_cur: [CLASSES + 1]?*Slab = @splat(null),
    free_list: [CLASSES + 1]?*anyopaque = @splat(null),
};
var mut: Mutator = .{};

fn waitWork() void {
    _ = std.c.pthread_cond_wait(&cv_work, &mu);
}
fn waitDone() void {
    _ = std.c.pthread_cond_wait(&cv_done, &mu);
}
extern "c" fn pthread_cond_timedwait_relative_np(cond: *std.c.pthread_cond_t, mutex: *std.c.pthread_mutex_t, rel: *const std.c.timespec) c_int;

/// `waitDone` for at most `ns`. It can return early: the caller looks at the clock again.
fn waitDoneFor(ns: i64) void {
    const n = @min(ns, std.time.ns_per_s / 10);
    var ts: std.c.timespec = undefined;
    if (comptime builtin.os.tag.isDarwin()) {
        // Relative: no clock to read. The wait is taken at most boundaries of a mutator that logs
        // faster than the collector applies, and lasts some tens of microseconds.
        ts = .{ .sec = 0, .nsec = @intCast(n) };
        _ = pthread_cond_timedwait_relative_np(&cv_done, &mu, &ts);
        return;
    }
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return waitDone();
    var nsec: i64 = @as(i64, ts.nsec) + n;
    if (nsec >= std.time.ns_per_s) {
        nsec -= std.time.ns_per_s;
        ts.sec += 1;
    }
    ts.nsec = @intCast(nsec);
    _ = std.c.pthread_cond_timedwait(&cv_done, &mu, &ts);
}
fn signalWork() void {
    _ = std.c.pthread_cond_signal(&cv_work);
}
fn broadcastDone() void {
    _ = std.c.pthread_cond_broadcast(&cv_done);
}
var q_head: ?*Log = null;
var q_tail: ?*Log = null;
var log_pool: ?*Log = null;
var pool_len: usize = 0; // guarded by mu
var q_len: usize = 0;
/// `q_len` for readers without the lock: the mutator spinning in `handoff`, the collector in `poll`.
var q_len_seen: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
/// Entries in the queued logs. Guarded by mu.
var q_entries: usize = 0;
var handed: u64 = 0;
var applied: u64 = 0;
var m_applied: u64 = 0;
/// Dead objects on their way from the collector to the mutator, which frees them: a list of chunks.
/// The collector fills chunks of its own (`c_ret`) and splices them onto `ret_shared`; a boundary
/// splices `ret_shared` onto the mutator's `ret_local`. Both are O(1) under `mu`, and a chunk is
/// freed once its objects are. As three PtrStacks (C), publishing copied the batch under the lock
/// whenever the mutator had not taken the previous one, the shared stack grew by realloc under the
/// lock, and each stack kept the capacity of the largest batch ever: 8 MiB apiece after one million
/// objects died at once.
/// Objects in a chunk (2 KiB with the header). A boundary looks at the clock between two chunks, so
/// a chunk is also the least it frees and what it can overrun its budget by.
const RET_CHUNK = 254;
const RetChunk = struct {
    next: ?*RetChunk,
    len: usize,
    items: [RET_CHUNK]*anyopaque,
};
const RetList = struct {
    head: ?*RetChunk = null,
    tail: ?*RetChunk = null,
    /// Objects in the list.
    n: usize = 0,

    fn push(l: *RetList, p: *anyopaque) void {
        var c = l.tail;
        if (c == null or c.?.len == RET_CHUNK) {
            @branchHint(.unlikely);
            c = l.grow();
        }
        const chunk = c.?;
        chunk.items[chunk.len] = p;
        chunk.len += 1;
        l.n += 1;
    }

    // Out of line: `push` is inlined into the collector's decrement path.
    noinline fn grow(l: *RetList) *RetChunk {
        const fresh: *RetChunk = @ptrCast(@alignCast(host.malloc(@sizeOf(RetChunk))));
        fresh.next = null;
        fresh.len = 0;
        if (l.tail) |t| t.next = fresh else l.head = fresh;
        l.tail = fresh;
        return fresh;
    }

    /// Moves the chunks of `from` behind those of `to`.
    fn splice(to: *RetList, from: *RetList) void {
        const h = from.head orelse return;
        if (to.tail) |t| t.next = h else to.head = h;
        to.tail = from.tail;
        to.n += from.n;
        from.* = .{};
    }
};
var ret_shared = RetList{}; // guarded by mu

/// The next returned object. It leaves the list before it is freed: freeing it can log entries, and
/// a log that fills up there runs a boundary, which frees returned objects itself.
inline fn retTake() *anyopaque {
    const c = mut.ret_local.head.?;
    const p = c.items[mut.ret_pos];
    mut.ret_pos += 1;
    mut.ret_local.n -= 1;
    if (mut.ret_pos == c.len) {
        mut.ret_local.head = c.next;
        if (c.next == null) mut.ret_local.tail = null;
        mut.ret_pos = 0;
        host.free(c);
    }
    return p;
}
var full_req: bool = false;
var full_done: u64 = 0;
var shutting: bool = false;
var coll_started: bool = false;
var defer_live: bool = true;
var boundary_keep: i64 = 0;

/// Garbage of a log comes back only after the collector applied it, and up to max_queued + 3 logs are
/// in flight (filling, queued, applying, returned), so allocation-heavy logs at log_cap 4096 held ~1 MiB
/// of dead cells (alloc_drop: 3.7 MiB of slabs for a 2.6 MiB live set). A log that made ALLOC_CUT
/// traced allocations ends at its next entry; logs that allocate little keep the full log_cap
/// (shorter logs cost rc_pair / lru_move a lot more boundaries for no memory gain).
noinline fn allocCut() void {
    mut.alloc_left = ALLOC_CUT;
    const l = mut.cur orelse return;
    if (l.n + 1 < mut.log_lim) {
        mut.log_lim = l.n + 1;
        dbg_alloc_cuts += 1;
    }
}

fn logNew() *Log {
    mut.log_lim = log_cap.load(.monotonic);
    mut.alloc_left = ALLOC_CUT;
    if (log_pool) |l| {
        log_pool = l.next;
        pool_len -= 1;
        l.n = 0;
        l.next = null;
        l.frees.len = 0;
        return l;
    }
    // C malloc + n/next/frees only. Do not `l.* = .{}` — that writes the whole
    // `a[]` on every new log (mutator-visible when field_store fills a log).
    // Own anonymous mapping, not malloc: only the entries actually written become
    // resident, and a trimmed log goes back to the OS (malloc kept whole-log
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

/// Queues `l` for the collector. Under mu.
fn enqueue(l: *Log) void {
    handed += 1;
    l.seq = handed;
    if (q_tail) |tail| tail.next = l else q_head = l;
    q_tail = l;
    q_len += 1;
    q_len_seen.store(q_len, .release);
    q_entries += l.n;
    signalWork();
}

/// Queued entries up to which a boundary gives up waiting for the collector once its share of the
/// pause is spent (4 MiB of logs). Past it the boundary waits until the collector has taken a log,
/// however long that takes: the queue must not grow without limit. The collector takes one every
/// `POLL_STEPS` steps of whatever it is doing, so that wait is some hundreds of microseconds; in C
/// it lasted until the detection or the cascade in progress was over.
const Q_SOFT_ENTRIES = 1 << 19;

/// Time a boundary watches the queue length before it sleeps on `cv_done`.
const SPIN_NS: i64 = 40_000;

/// `wait_until` (an `rt_nanos` time) ends the back-pressure wait of this boundary.
fn handoff(wait_until: i64) void {
    lock();
    if (!coll_started) {
        coll_started = true;
        const t = std.Thread.spawn(.{}, collectorMain, .{}) catch {
            host.rt_panic("epoch GC: cannot start the collector thread");
        };
        t.detach();
    }
    if (mut.cur) |l| {
        if (l.n != 0 or l.frees.len != 0) {
            enqueue(l);
            mut.cur = null;
        }
    }
    if (max_queued == 0) {
        const qe = host.getenv_i64("KX_GC_MAX_QUEUED", 0);
        if (qe > 0) {
            max_queued = @intCast(qe);
            q_fixed = true;
        } else max_queued = Q_ADAPT_START;
        q_target_ns = @max(host.getenv_i64("KX_GC_TARGET_PAUSE_US", TARGET_PAUSE_US_DEFAULT), 0) *| 1000;
    }
    // The collector is behind. Waiting for it is the pause: C waits until the queue is short again,
    // however long the collector takes (5-18 ms while it released a million objects that died
    // together). The wait ends with this boundary's share of the pause instead; the mutator then
    // goes on with a longer queue, and meets the same wait at its next boundary.
    var d: i64 = 0;
    if (q_len > max_queued) {
        const w0 = host.rt_nanos();
        var now = w0;
        // The collector takes a log every few tens of microseconds: most waits end sooner than a
        // sleep on the condition variable and the wake-up after it take, so look at the queue
        // length for a moment first.
        if (wait_until != NO_DEADLINE) {
            unlock();
            const spin_until = @min(w0 + SPIN_NS, wait_until);
            var spins: u32 = 0;
            while (q_len_seen.load(.acquire) > max_queued) {
                std.atomic.spinLoopHint();
                spins +%= 1;
                if (spins & 63 == 0) {
                    now = host.rt_nanos();
                    if (now >= spin_until) break;
                }
            }
            now = host.rt_nanos();
            lock();
        }
        while (q_len > max_queued) {
            if (q_fixed or q_entries > Q_SOFT_ENTRIES or wait_until == NO_DEADLINE) {
                waitDone();
            } else if (now < wait_until) {
                waitDoneFor(wait_until - now);
            } else {
                break; // the limit stays: the next boundary waits again, and the queue stays short
            }
            now = host.rt_nanos();
        }
        d = @max(d, now - w0);
    }
    if (!q_fixed) queueAdapt(d);
    mut.ret_local.splice(&ret_shared);
    m_applied = applied;
    if (mut.cur == null) mut.cur = logNew();
    unlock();
}

/// The roots that wait for a major collection: one bit per 8 bytes of a 64 KiB page that has any,
/// 1 KiB a page. They were a pointer stack: every stable object the program had dropped a
/// reference to since the last major collection, which with small objects is most of the heap
/// (ops: 8 bytes for each 40-byte object, 0.5 MiB of a 6.5 MiB process; 8 to 16 MiB with a million
/// objects live). A member has BUF_BIT set, as on any root list.
const DeferPage = struct {
    pg: usize,
    /// Index in `DeferSet.pages`.
    at: usize,
    n: usize,
    bits: [DEFER_WORDS]u64,
};
const DEFER_WORDS = PAGE / 8 / 64;
const DeferSet = struct {
    len: usize = 0,
    pages: obj.PtrStack = .{},
    /// Like `slab_dir`: page number -> its bitmap. Zero pages until touched.
    dir: [SLAB_DIR_TOP]?[*]?*DeferPage = @splat(null),

    fn push(self: *DeferSet, p: *anyopaque) void {
        const a = @intFromPtr(p);
        const pg = a >> PAGE_SHIFT;
        var d = self.dir[pg >> 16];
        if (d == null) {
            d = @ptrCast(@alignCast(mapAnon((1 << 16) * @sizeOf(?*DeferPage), false)));
            self.dir[pg >> 16] = d;
        }
        var dp = d.?[pg & 0xffff];
        if (dp == null) {
            dp = @ptrCast(@alignCast(host.calloc(@sizeOf(DeferPage))));
            dp.?.pg = pg;
            dp.?.at = self.pages.len;
            self.pages.push(dp);
            d.?[pg & 0xffff] = dp;
        }
        const bit = (a & (PAGE - 1)) >> 3;
        const m = @as(u64, 1) << @intCast(bit & 63);
        const w = &dp.?.bits[bit >> 6];
        if (w.* & m != 0) return;
        w.* |= m;
        dp.?.n += 1;
        self.len += 1;
    }

    fn drop(self: *DeferSet, dp: *DeferPage) void {
        const last: *DeferPage = @ptrCast(@alignCast(self.pages.pop().?));
        if (last != dp) {
            last.at = dp.at;
            self.pages.set(dp.at, last);
        }
        self.dir[dp.pg >> 16].?[dp.pg & 0xffff] = null;
        host.free(dp);
    }

    /// Every member goes to `to` and the set is left empty, with no bitmap.
    fn drainTo(self: *DeferSet, to: *obj.PtrStack) void {
        while (self.pages.len != 0) {
            const dp: *DeferPage = @ptrCast(@alignCast(self.pages.at(self.pages.len - 1).?));
            for (dp.bits, 0..) |word, wi| {
                var w = word;
                while (w != 0) : (w &= w - 1) {
                    to.push(@ptrFromInt((dp.pg << PAGE_SHIFT) | ((wi << 6 | @ctz(w)) << 3)));
                }
            }
            self.drop(dp);
        }
        self.pages.deinit();
        self.len = 0;
    }

    /// Returns the members that died (zombies) to the mutator.
    fn sweep(self: *DeferSet) void {
        var i = self.pages.len;
        while (i != 0) {
            i -= 1;
            const dp: *DeferPage = @ptrCast(@alignCast(self.pages.at(i).?));
            for (&dp.bits, 0..) |*word, wi| {
                var w = word.*;
                while (w != 0) : (w &= w - 1) {
                    const s: *anyopaque = @ptrFromInt((dp.pg << PAGE_SHIFT) | ((wi << 6 | @ctz(w)) << 3));
                    if (!has(s, ZOMBIE_BIT)) continue;
                    clrBit(s, ZOMBIE_BIT);
                    clrBit(s, kx.BUF_BIT);
                    retPush(s);
                    word.* &= ~(w & (~w +% 1));
                    dp.n -= 1;
                    self.len -= 1;
                }
            }
            // The page that takes its place in `pages` was visited already (it came from the end).
            if (dp.n == 0) self.drop(dp);
        }
    }

    fn bytes(self: *const DeferSet) usize {
        return self.pages.len * @sizeOf(DeferPage) + self.pages.cap * @sizeOf(usize);
    }
};

var c_roots = obj.PtrStack{};
var c_work = obj.PtrStack{};
var c_ret = RetList{};
var c_deferred = DeferSet{};
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

/// `c_dying` entry: a dead object whose children are still to be released; the low bit says that it
/// goes back to the mutator after that.
const DYING_RETURN: usize = 1;

/// Releases the children of dead `p`, and theirs when they die of it. The loop is the collector's
/// longest operation after a detection: a million objects that die together took 10-20 ms, during
/// which the queue was not served, so the mutator filled it and then waited at every boundary until
/// the cascade was over. Now a queued log is applied every `POLL_STEPS` objects (its own deaths
/// join this loop), and what has been released is handed to the mutator on the way.
/// An object is returned only after its children were visited: once published, the mutator may free
/// it at any moment.
fn releaseChildren(p: *anyopaque, ret: usize) void {
    c_found += 1;
    if (has(p, STABLE_BIT)) {
        clrBit(p, STABLE_BIT);
        c_stable_n -= 1;
    }
    clrBit(p, DEAD_BIT);
    obj.setColor(p, obj.BLACK);
    c_dying.push(@ptrFromInt(@intFromPtr(p) | ret));
    if (c_releasing) return;
    c_releasing = true;
    const tm = coll_tm;
    const pm = tm.*;
    tm.* = kx.TRAV_RELEASE;
    while (c_dying.len != 0) {
        const e = @intFromPtr(c_dying.pop().?);
        const x: *anyopaque = @ptrFromInt(e & ~DYING_RETURN);
        if (obj.vtab(x).trav) |trav| trav(x, releaseDeadChild);
        if (e & DYING_RETURN != 0) retPush(x);
        // Not for an object that dies alone: a log of those is short as it is, and a log applied
        // in the middle of it only kept its garbage from the mutator longer.
        if (c_dying.len != 0) tick();
    }
    tm.* = pm;
    c_releasing = false;
}

// Both out of line: they keep `decApply` small enough to be inlined into `applyLog`. With the
// death path inlined into it instead, every decrement paid a call and a frame, and a mutator
// waiting on the queue paid with it (field_store +15-20%, rc_pair +7%).
noinline fn releaseDead(p: *anyopaque) void {
    // Held by the detection in progress: `settle` returns it.
    if (has(p, MARKED_BIT)) {
        setBit(p, ZOMBIE_BIT);
        releaseChildren(p, 0);
        return;
    }
    releaseChildren(p, DYING_RETURN);
}
noinline fn releaseZombie(p: *anyopaque) void {
    c_zombies += 1;
    setBit(p, ZOMBIE_BIT);
    releaseChildren(p, 0);
}

/// Collector steps (an object released, traced, scanned or settled) between two looks at the queue:
/// some tens of microseconds, about what applying a log takes.
const POLL_STEPS: u32 = 2048;
var poll_steps: u32 = POLL_STEPS;
var c_steps: u32 = 0;
/// Steps until the next `poll`: `poll_steps`, or a multiple of it (see `poll`).
var c_poll_at: u32 = POLL_STEPS;
var c_detecting: bool = false;
/// A detection stretches the interval between two polls by POLL_DEBT_RATE for every `c_threshold`
/// roots waiting for the next one, at most POLL_DEBT_MAX times: some hundreds of microseconds,
/// the time a boundary may have to wait for the collector to take a log once the queue is full.
const POLL_DEBT_RATE: usize = 8;
const POLL_DEBT_MAX: usize = 16;
/// Logs being applied (2 when `poll` applies one inside another's cascade) and the newest sequence
/// number applied: `applied` follows it once no older log is still open.
var c_open_logs: u32 = 0;
var c_seq_done: u64 = 0;

inline fn tick() void {
    c_steps += 1;
    if (c_steps >= c_poll_at) {
        @branchHint(.unlikely);
        poll();
    }
}

/// From the collector's long loops, between two `trav` calls (never inside one: a log brings the
/// `rt_gc_free_later` memory that a traversal may be reading): hands what it has released to the
/// mutator and applies one queued log, so the queue is served every `POLL_STEPS` steps whatever the
/// collector is doing, and the loop still gets most of the time when the mutator logs faster than
/// the collector applies. Applying out of order is sound for the counts: the increments of every log
/// taken are applied before any of its decrements, so a count only reaches zero when the object is
/// dead at the end of the newest log.
/// No nesting beyond one level: a log applied here runs no detection, and the deaths it causes inside
/// a cascade join that cascade.
///
/// A detection that applied a log every `POLL_STEPS` steps let the mutator run at full speed while
/// it traced, and a program building a large structure then made roots as fast as the detection
/// retired them: each detection started with the roots of the previous one's whole duration, twice
/// as many each time (438855 roots, 26 MiB of root, mark and work stacks with a million objects
/// live). So a detection serves the queue less often the more roots wait for the next one: the
/// mutator then meets a full queue and its boundaries wait, each for its bounded share of the pause.
/// The stretch starts at an eighth of the threshold: started at twice the threshold, the roots
/// waiting settled near 20000 where they are 7000 now (0.5 MiB of stacks on a 6 MiB heap).
noinline fn poll() void {
    c_steps = 0;
    c_poll_at = poll_steps;
    if (c_detecting) {
        const debt = @min(c_roots.len * POLL_DEBT_RATE / c_threshold, POLL_DEBT_MAX);
        if (debt > 1) c_poll_at *|= @intCast(debt);
    }
    publishReturns();
    if (q_len_seen.load(.acquire) == 0) return;
    lock();
    const l = takeLog();
    unlock();
    if (l) |log| {
        dbg_polled += 1;
        applyTaken(log);
    }
}

/// The oldest queued log. Under mu.
fn takeLog() ?*Log {
    const l = q_head orelse return null;
    q_head = l.next;
    if (q_head == null) q_tail = null;
    q_len -= 1;
    q_len_seen.store(q_len, .release);
    q_entries -= l.n;
    broadcastDone();
    return l;
}

fn applyTaken(l: *Log) void {
    var i: usize = 0;
    while (i < l.frees.len) : (i += 1) host.free(l.frees.at(i));
    l.frees.len = 0;
    c_open_logs += 1;
    applyLog(l);
    c_open_logs -= 1;
    c_seq_done = @max(c_seq_done, l.seq);
    lock();
    if (c_open_logs == 0) applied = c_seq_done;
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
    unlock();
}

fn possibleRoot(p: *anyopaque) void {
    obj.setColor(p, obj.PURPLE);
    if (!has(p, kx.BUF_BIT)) {
        setBit(p, kx.BUF_BIT);
        c_roots.push(p);
    }
}

/// A possible root that is probably live (`h`, its header, has neither BUF_BIT nor CAND_BIT): not
/// worth a detection of its own.
/// A stable object waits in `c_live_def` for the next flush. One the detection in progress has
/// marked (the log is applied from `poll`) waits for a major, like the roots that detection defers
/// itself, and keeps its color so the detection still scans it. As a root in `c_roots` it started
/// the next detection at once, and that one the next, for as long as the mutator touched what was
/// being traced; in `c_live_def` it came back with every flush.
/// Out of line, like `releaseDead`: once per object and flush, and `decApply` must stay small.
noinline fn deferLive(p: *anyopaque, h: u64) void {
    setBit(p, kx.BUF_BIT);
    if (h & MARKED_BIT != 0) {
        c_deferred.push(p);
        return;
    }
    obj.setColor(p, obj.PURPLE);
    c_live_def.push(p);
}

// Inlined by request: with two callers of `applyLog` (the collector loop and `poll`) LLVM left it
// as a call per decrement, which cost rc_pair a quarter of its speed.
inline fn decApply(p: *anyopaque) void {
    const h = obj.header(p).*;
    if (h & kx.CNT_MASK == 0) host.rt_panic("epoch GC: reference count underflow");
    if ((h & (STABLE_BIT | MARKED_BIT)) != 0 and (h & kx.CNT_MASK) > 1 and defer_live) {
        obj.header(p).* = (h - 1) | DIRTY_BIT;
        if ((h & (kx.BUF_BIT | CAND_BIT)) == 0) deferLive(p, h);
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
    if ((h & (STABLE_BIT | MARKED_BIT)) != 0 and defer_live) {
        obj.header(p).* = h | DIRTY_BIT;
        if ((h & (kx.BUF_BIT | CAND_BIT)) == 0) deferLive(p, h);
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
    // Saturating: a carry out of the CRC field would land in MARKED_BIT. An object with 2^23
    // references from the traced graph then keeps a positive external count, and stays.
    if (h & CRC_MASK != CRC_MASK) h += @as(u64, 1) << CRC_SHIFT;
    if (h & MARKED_BIT == 0) {
        // First visit of this detection. Not "not gray yet" (C): a log applied meanwhile repaints a
        // gray object purple, and its DIRTY bit, set by that log, must not be cleared again.
        h = (h & ~(kx.COLOR_MASK | DIRTY_BIT)) | (@as(u64, obj.GRAY) << kx.COLOR_SHIFT) | MARKED_BIT;
        obj.header(p).* = h;
        // C `stack_push(&tw->marked, t)`, which the port had dropped: only the roots were settled
        // after a detection. An object that lost the edge MarkGray reached it through stayed gray
        // with its CRC, was not traced through again, and a garbage cycle behind it leaked.
        c_marked.push(p);
        c_work.push(p);
        return;
    }
    obj.header(p).* = h;
}

fn sbChild(t: ?*anyopaque) callconv(.c) void {
    const p = t orelse return;
    if (!isTraced(p)) return;
    const h = obj.header(p).*;
    if (h & (CAND_BIT | DEAD_BIT) != 0 or h & kx.CNT_MASK == 0) return;
    // Not black: gray or white (marked by this detection) or purple (a buffered root). Either pins the object
    // while it waits in `c_black`.
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
    // Died since it was marked (a log applied by `poll`): its children were released and may be
    // freed already. `settle` returns it.
    if (h & kx.CNT_MASK == 0) return;
    const ext: i64 = @as(i64, @intCast(h & kx.CNT_MASK)) - @as(i64, @intCast((h >> CRC_SHIFT) & CRC_MAX));
    if (ext > 0) {
        obj.setColor(x, obj.BLACK);
        setCrc(x, 0);
        promote(x);
        c_black.push(x);
        while (c_black.len != 0) {
            const y = c_black.pop().?;
            if (obj.refCount(y) == 0) continue;
            if (obj.vtab(y).trav) |trav| trav(y, sbChild);
            tick();
        }
    } else {
        obj.setColor(x, obj.WHITE);
        if (obj.vtab(x).trav) |trav| trav(x, scanChild);
    }
}

fn scanChild(t: ?*anyopaque) callconv(.c) void {
    // Only what the detection holds (MARKED) may wait on the work stack: anything else can die and be freed by
    // the mutator while it waits (and `scanOne` looks at gray objects only, which are all marked).
    if (t) |p| if (isTraced(p) and (obj.header(p).* & (CAND_BIT | MARKED_BIT)) == MARKED_BIT) c_work.push(p);
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
        // A member that died meanwhile is only flagged DEAD: its children keep their counts.
        if (obj.vtab(x).trav) |trav| trav(x, cwChild);
        tick();
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
            // A log applied here changes a count or an edge of this set only by touching a member,
            // and a touched member fails the set in `validate`.
            tick();
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
        // The set is garbage from here on, whatever the logs applied on the way say: only stale
        // hints and write-barrier entries can still name a member, and a hint that buffers one
        // makes it a zombie below.
        for (members) |m| {
            if (obj.vtab(m.?).trav) |trav| trav(m.?, freeCycleChild);
            tm.* = kx.TRAV_RELEASE; // a cascade inside restored its own saved mode
            tick();
        }
        tm.* = pm;
        for (members) |mm| {
            const x = mm.?;
            clrBit(x, CAND_BIT);
            obj.setColor(x, obj.BLACK);
            setCrc(x, 0);
            obj.header(x).* &= ~kx.CNT_MASK;
            if (has(x, kx.BUF_BIT)) setBit(x, ZOMBIE_BIT) else retPush(x);
            tick();
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
    if (major) {
        obj.PtrStack.moveFrom(&c_roots, &c_live_def);
        c_deferred.drainTo(&c_roots);
    }
    var roots = c_roots;
    c_roots = .{};
    // The roots keep BUF_BIT until the second loop: a cascade below applies queued logs (`poll`),
    // and a root that dies of one must stay a zombie, not go back to the mutator from under this list.
    var i: usize = 0;
    while (i < roots.len) : (i += 1) {
        const s = roots.at(i).?;
        if (has(s, DEAD_BIT) and !has(s, CAND_BIT | ZOMBIE_BIT)) {
            roots.set(i, null);
            obj.header(s).* &= ~(DEAD_BIT | kx.BUF_BIT);
            releaseDead(s);
        }
    }
    var k: usize = 0;
    i = 0;
    while (i < roots.len) : (i += 1) {
        const s = roots.at(i) orelse continue;
        clrBit(s, kx.BUF_BIT);
        if (has(s, ZOMBIE_BIT)) {
            clrBit(s, ZOMBIE_BIT);
            retPush(s);
            continue;
        }
        if (has(s, CAND_BIT | DEAD_BIT)) continue;
        if (obj.refCount(s) > 0) {
            obj.setColor(s, obj.GRAY);
            setCrc(s, 0);
            clrBit(s, DIRTY_BIT);
            setBit(s, MARKED_BIT);
            roots.set(k, s);
            k += 1;
        }
    }
    roots.len = k;
    return roots;
}

/// Capacity `c_marked` keeps between detections (64 KiB).
const MARKED_KEEP = 8192;

/// End of a detection for an object it marked (a root, or in `c_marked`): it lets go of it.
fn settle(x: *anyopaque) void {
    const h = obj.header(x).* & ~MARKED_BIT;
    obj.header(x).* = h;
    if (h & CAND_BIT != 0) return;
    if (obj.color(x) == obj.GRAY or obj.color(x) == obj.WHITE) obj.setColor(x, obj.BLACK);
    setCrc(x, 0);
    // Died during the detection (`releaseDead`). A buffered one stays a zombie of its root list.
    if (h & (ZOMBIE_BIT | kx.BUF_BIT) == ZOMBIE_BIT) {
        clrBit(x, ZOMBIE_BIT);
        retPush(x);
    }
}

/// One cycle detection from the buffered roots. Its loops call `tick`, so queued logs are applied
/// while it runs: counts, colors and DIRTY bits change under it, and objects die. What keeps it
/// sound: every object on its stacks is pinned (MARKED_BIT, BUF_BIT or CAND_BIT: a dead one is not
/// returned before `settle`) and skipped once dead, its children having been released; and whatever
/// it concludes is only a candidate set, which `validate` frees if no member was touched since it
/// was first marked.
fn detect(major: bool) void {
    var roots = detectPrepare(major);
    c_hit_stable = false;
    c_detecting = true;
    // One root at a time, and the roots are not copied to `c_marked` (they are settled from
    // `roots`): with every root on both stacks a detection held 24 bytes per root, 0.8 MiB for
    // the 21000 roots a program building its data leaves while one detection runs.
    var visits: i64 = 0;
    var i: usize = 0;
    while (i < roots.len) : (i += 1) {
        c_work.push(roots.at(i).?);
        while (c_work.len != 0) {
            const x = c_work.pop().?;
            if (obj.refCount(x) == 0) continue;
            visits += 1;
            if (obj.vtab(x).trav) |trav| trav(x, mgChild);
            tick();
        }
    }
    c_traversed += visits;
    i = 0;
    while (i < roots.len) : (i += 1) {
        c_work.push(roots.at(i).?);
        while (c_work.len != 0) {
            scanOne(c_work.pop().?);
            tick();
        }
    }
    i = 0;
    while (i < roots.len) : (i += 1) collectWhite(roots.at(i).?);
    if (!major and c_hit_stable) {
        i = 0;
        while (i < roots.len) : (i += 1) {
            const s = roots.at(i).?;
            if (obj.refCount(s) != 0 and !has(s, CAND_BIT) and !has(s, kx.BUF_BIT)) {
                setBit(s, kx.BUF_BIT);
                c_deferred.push(s);
            }
        }
    }
    i = 0;
    while (i < roots.len) : (i += 1) {
        settle(roots.at(i).?);
        tick();
    }
    roots.deinit();
    i = 0;
    while (i < c_marked.len) : (i += 1) {
        settle(c_marked.at(i).?);
        tick();
    }
    // They held every object this detection reached: do not keep that for a small one.
    if (c_marked.cap > MARKED_KEEP) c_marked.deinit() else c_marked.len = 0;
    if (c_work.cap > MARKED_KEEP) c_work.deinit();
    closeSets();
    c_detecting = false;
    c_poll_at = poll_steps;
}

fn flushLiveDef() void {
    c_after_flush = true;
    dbg_flushes += 1;
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
    if (c_ret.head == null) return;
    lock();
    ret_shared.splice(&c_ret);
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
    if (major) dbg_majors += 1;
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

/// Logs applied in a row without a detection after which the root threshold halves.
const QUIET_LOGS: u32 = 64;
var c_quiet: u32 = 0;

/// Only a detection lowered the threshold, so one raised by the unproductive detections of a
/// program's start stayed there once roots stopped arriving, and the log size with it: 256 KiB logs
/// (2 MiB resident in ops, and slower than 32 KiB ones that fit the cache) for a program that makes
/// no garbage cycles at all.
fn thresholdDecay() void {
    c_quiet = 0;
    if (c_threshold <= c_min_threshold) return;
    c_threshold = @max(c_threshold / 2, c_min_threshold);
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
    c_deferred.sweep();
    c_zombies = 0;
}

/// The collector thread's own `rt_trav_mode` (thread-local in the runtime). Taken once
/// (`travMode`): on Darwin every thread-local access is a `_tlv_get_addr` call.
var coll_tm: *c_int = undefined;

fn collectorMain() void {
    coll_tm = travMode();
    lock();
    while (true) {
        while (q_head == null and !full_req and !shutting) waitWork();
        if (takeLog()) |l| {
            unlock();
            applyTaken(l);
            // Between two logs only, never from `poll`: these walk the root lists and the candidate
            // batches, which a cascade or a detection in progress relies on.
            if (c_live_def.len >= 4096 and (@as(i64, @intCast(c_live_def.len)) * defer_flush >= c_stable_n or c_live_def.len >= DEFER_FLUSH_MAX)) {
                flushLiveDef();
            } else if (c_zombies >= 4096 and c_zombies * 2 >= c_live_def.len + c_deferred.len) {
                sweepDeferred();
            }
            const freed = validateReady(c_seq_done, false);
            const major_at = major_ratio * @max(c_stable_n, @as(i64, @intCast(c_threshold)));
            if (c_roots.len >= c_threshold or @as(i64, @intCast(c_deferred.len)) >= major_at) {
                const major = force_major or @as(i64, @intCast(c_deferred.len)) >= major_at;
                detectAdaptive(major);
                c_quiet = 0;
            } else {
                c_quiet += 1;
                if (c_quiet >= QUIET_LOGS) thresholdDecay();
            }
            gc_st.reclaimed += @intCast(freed);
            publishReturns();
            lock();
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
    m_held.push(@ptrFromInt(if (mut.cur != null and mut.cur.?.n != 0) handed + 1 else handed));
}

/// The calling thread's `rt_trav_mode`, looked up once per batch. The address goes through a
/// volatile load: LLVM treats a thread-local's address as a constant, so it folds a pointer copied
/// from it (in a local, a global stored once, or the result of a call) back into a lookup at every
/// use, and on Darwin each lookup is a `_tlv_get_addr` call: two per object freed, 8% of the
/// collector's time in alloc_drop.
fn travMode() *c_int {
    var p: *c_int = &host.rt_trav_mode;
    return @as(*volatile *c_int, &p).*;
}

const NO_DEADLINE = std.math.maxInt(i64);

/// Frees returned objects, a chunk at a time, until `deadline` (an `rt_nanos` time; NO_DEADLINE: all
/// of them). What is left goes at later boundaries and, a few per allocation, in `freePaced`.
/// C `process_returns`; the port had dropped the budget, so one boundary freed everything the
/// collector had returned: a pause of 11-18 ms after a million objects died together.
fn processReturns(deadline: i64) void {
    if (m_held.len != 0) freeHeld(false);
    const tm = travMode();
    while (mut.ret_local.head) |c| {
        // The chunk leaves the list first (see `retTake`).
        var i = mut.ret_pos;
        mut.ret_local.head = c.next;
        if (c.next == null) mut.ret_local.tail = null;
        mut.ret_local.n -= c.len - i;
        mut.ret_pos = 0;
        while (i < c.len) : (i += 1) freeReturned(c.items[i], tm);
        host.free(c);
        if (deadline != NO_DEADLINE and host.rt_nanos() > deadline) break;
    }
}

// C free_returned stays out of line. Inlining the paced loop into allocTrace
// made newObj too fat for op_alloc (no-LTO `call newObj` every iteration).
noinline fn freePaced() void {
    const back = mut.ret_local.n;
    var k: usize = if (back > 65536) 16 else if (back > 16384) 8 else if (back > 4096) 4 else 2;
    const tm = travMode();
    while (k > 0 and mut.ret_local.head != null) : (k -= 1) freeReturned(retTake(), tm);
}

// C: `__attribute__((noinline)) void log_first` so log_op has no stack frame.
noinline fn logFirst() void {
    // C: a value <= 0 is ignored. Here 0 made every logged operation a boundary and a negative
    // one was cast to usize.
    const fixed = host.getenv_i64("KX_GC_LOG_CAP", 0);
    if (fixed > 0) {
        log_cap.store(@intCast(@min(fixed, LOG_CAP)), .monotonic);
        log_cap_fixed = true;
    } else logCapFollow();
    lock();
    mut.cur = logNew();
    unlock();
}

inline fn logOp(e: usize) void {
    // C log_op: `if (cur == NULL) log_first(); cur->a[cur->n++] = e; if (n >= cap) boundary();`
    if (mut.cur == null) {
        @branchHint(.unlikely);
        logFirst();
    }
    const l = mut.cur.?;
    const n = l.n;
    l.a[n] = e;
    const n1 = n + 1;
    l.n = n1;
    if (n1 >= mut.log_lim) {
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

/// C: KX_GC_TARGET_PAUSE_US defaults to 3000. A boundary here aims at 1 ms.
const TARGET_PAUSE_US_DEFAULT: i64 = 1000;
const FREE_BUDGET_MIN_NS: i64 = 100_000;
var free_budget_ns: i64 = -1;

/// Time a boundary may spend freeing returned objects, counted from its start: KX_GC_FREE_BUDGET_US,
/// by default a quarter of the target pause. Most returned objects are freed a few per allocation
/// (`freePaced`); the boundary's share is for a program that frees without allocating.
fn freeBudgetNs() i64 {
    if (free_budget_ns < 0) {
        const us = host.getenv_i64("KX_GC_FREE_BUDGET_US", -1);
        free_budget_ns = if (us >= 0) us *| 1000 else @max(@divTrunc(q_target_ns, 4), FREE_BUDGET_MIN_NS);
    }
    return free_budget_ns;
}

/// Time a boundary may wait for the collector, counted from its start: 2/5 of the target pause.
/// The rest is for freeing returned objects (at least a chunk of them) and releasing slabs.
fn waitBudgetNs() i64 {
    return @divTrunc(q_target_ns, 5) * 2;
}

// Out of line like C: inlining this into log_op gives every retain/store a fat frame.
noinline fn boundary() void {
    if (mut.in_boundary) {
        lock();
        enqueue(mut.cur.?);
        mut.cur = logNew();
        unlock();
        return;
    }
    mut.in_boundary = true;
    const t0 = host.rt_nanos();
    handoff(t0 + waitBudgetNs());
    // A boundary that spent its time waiting still frees for FREE_BUDGET_MIN_NS: otherwise all it
    // frees is one chunk, and the rest goes a few per allocation in `freePaced`.
    processReturns(@max(t0 + freeBudgetNs(), host.rt_nanos() + FREE_BUDGET_MIN_NS));
    slabFlush();
    obj.statsAddPause(&gc_st, host.rt_nanos() - t0);
    mut.in_boundary = false;
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
    // C logs a null as well, and the collector then reads the header at address 0.
    if (p) |q| logOp(@intFromPtr(q) | OP_ROOT);
}
pub export fn rt_gc_free_later(p: ?*anyopaque) void {
    const q = p orelse return;
    if (mut.cur == null) {
        host.free(q);
        return;
    }
    mut.cur.?.frees.push(q);
}

fn exitDrain() bool {
    return host.getenv_present("KX_GC_EXIT_DRAIN") or host.getenv_present("KX_GC_STATS");
}

pub export fn rt_gc_collect() void {
    if (mut.in_boundary) return;
    // Tests and leak-check need a drain; standalone benches set KX_GC_STATS or KX_GC_EXIT_DRAIN.
    // Default C skips drain unless leak-check / malloc / EXIT_DRAIN. Native tests always drain.
    mut.in_boundary = true;
    const t0 = host.rt_nanos();
    while (true) {
        const had = mut.cur != null and (mut.cur.?.n != 0 or mut.cur.?.frees.len != 0);
        handoff(NO_DEADLINE);
        lock();
        while (q_head != null) waitDone();
        const want = full_done + 1;
        full_req = true;
        signalWork();
        while (full_done < want) waitDone();
        mut.ret_local.splice(&ret_shared);
        m_applied = applied;
        unlock();
        const returned = mut.ret_local.n;
        processReturns(NO_DEADLINE);
        if (!had and returned == 0 and !(mut.cur != null and (mut.cur.?.n != 0 or mut.cur.?.frees.len != 0))) break;
    }
    freeHeld(true); // the queue is empty and every handed log applied
    obj.statsAddPause(&gc_st, host.rt_nanos() - t0);
    mut.in_boundary = false;
}

pub export fn rt_gc_name() [*:0]const u8 {
    return "epoch";
}
/// Tests: the freeing budget of a boundary (KX_GC_FREE_BUDGET_US); negative restores the default.
pub fn debugSetFreeBudgetUs(us: i64) void {
    free_budget_ns = us * 1000;
}
/// Tests: collector steps between two looks at the queue (0 restores the default). With 1 a queued
/// log is applied between any two objects a detection or a cascade visits.
pub fn debugSetPollSteps(n: u32) void {
    poll_steps = if (n == 0) POLL_STEPS else n;
    c_poll_at = poll_steps;
}
/// Tests: every detection is a major one (it traces through stable objects too).
pub fn debugForceMajor(on: bool) void {
    force_major = on;
}
var force_major: bool = false;
/// Tests: returned objects the mutator has not freed yet.
pub fn debugReturnsPending() usize {
    return mut.ret_local.n;
}
pub export fn rt_gc_stats(out: *kx.Stats) void {
    lock();
    out.* = gc_st;
    if (host.getenv_present("KX_GC_DEBUG")) epochDebug();
    unlock();
}

fn epochDebug() void {
    const mib = 1.0 / 1048576.0;
    _ = std.c.printf("epoch: mem MiB slabs=%.2f logs=%lld(%.2f) stacks(cap) roots=%.2f deferred=%.2f live_def=%.2f work=%.2f black=%.2f marked=%.2f ret-pending=%zu cw=%.2f dying=%.2f\n", @as(f64, @floatFromInt(dbg_slab_bytes)) * mib, @as(c_longlong, dbg_log_allocs), @as(f64, @floatFromInt(dbg_log_allocs * @sizeOf(Log))) * mib, capMib(&c_roots), @as(f64, @floatFromInt(c_deferred.bytes())) * mib, capMib(&c_live_def), capMib(&c_work), capMib(&c_black), capMib(&c_marked), c_ret.n + ret_shared.n + mut.ret_local.n, capMib(&cw_m) + capMib(&cw_ends), capMib(&c_dying));
    _ = std.c.printf("epoch: threshold=%zu log_cap=%zu stable=%lld collections=%lld logs_handed=%llu alloc_cuts=%lld max_queued=%zu\n", c_threshold, log_cap.load(.monotonic), @as(c_longlong, c_stable_n), @as(c_longlong, gc_st.collections), @as(c_ulonglong, handed), @as(c_longlong, dbg_alloc_cuts), max_queued);
    _ = std.c.printf("epoch: majors=%lld live_def_flushes=%lld logs_polled=%lld traversed=%lld found=%lld defer_flush=%lld major_ratio=%lld\n", @as(c_longlong, dbg_majors), @as(c_longlong, dbg_flushes), @as(c_longlong, dbg_polled), @as(c_longlong, c_traversed), @as(c_longlong, c_found), @as(c_longlong, defer_flush), @as(c_longlong, major_ratio));
}
var dbg_alloc_cuts: i64 = 0;
var dbg_polled: i64 = 0;
var dbg_majors: i64 = 0;
var dbg_flushes: i64 = 0;
fn capMib(s: *const obj.PtrStack) f64 {
    return @as(f64, @floatFromInt(s.cap * 8)) / 1048576.0;
}
var dbg_slab_bytes: i64 = 0;
var dbg_log_allocs: i64 = 0;
