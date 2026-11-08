//! Standalone host for symbols `kxgc.h` says the runtime provides.
//! KotlinX supplies these from `compiler/runtime/runtime.c`. This file is the
//! native equivalent used by tests and benches.
//!
//! Clock:
//! - macOS: `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` (same as KotlinX runtime.c)
//! - elsewhere: `clock_gettime(CLOCK_MONOTONIC)`
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub export var rt_rel_draining: c_int = 0;
pub export var rt_relo_owner: c_int = 0;
pub export threadlocal var rt_trav_mode: c_int = 0;

/// Pause histogram for percentiles (KX_GC_STATS-style p50/p99). runtime.c keeps every pause in a
/// growing array; an epoch run has hundreds of thousands of boundary pauses, so that array was
/// ~2 MiB of the bench's peak RSS. Log-linear buckets instead: exact below 16 ns, then 16 linear
/// sub-buckets per power of two (≤ 1/16 relative error), fixed 7.5 KiB.
const PAUSE_SUB_BITS = 4;
const PAUSE_SUB: u64 = 1 << PAUSE_SUB_BITS;
const PAUSE_BUCKETS = (64 - PAUSE_SUB_BITS) * PAUSE_SUB; // exponents up to 62 (largest i64)
var gc_pause_hist: [PAUSE_BUCKETS]u64 = @splat(0);
var gc_pause_n: u64 = 0;
var gc_pause_max: u64 = 0;

fn pauseBucket(v: u64) usize {
    if (v < PAUSE_SUB) return @intCast(v);
    const e: u64 = 63 - @clz(v);
    const shift: u6 = @intCast(e - PAUSE_SUB_BITS);
    return @intCast((e - PAUSE_SUB_BITS + 1) * PAUSE_SUB + ((v >> shift) & (PAUSE_SUB - 1)));
}

/// Largest value that falls into bucket `i`.
fn pauseBucketTop(i: usize) u64 {
    if (i < PAUSE_SUB) return i;
    const g = i / PAUSE_SUB;
    const shift: u6 = @intCast(g - 1);
    const low = (PAUSE_SUB + i % PAUSE_SUB) << shift;
    return low + ((@as(u64, 1) << shift) - 1);
}

/// Nearest-rank percentile (q in 0..1) of the recorded pauses in ns, as the top of its bucket
/// (capped by the largest pause); 0 with no pauses.
pub fn pausePercentileNs(q: f64) i64 {
    if (gc_pause_n == 0) return 0;
    const n: f64 = @floatFromInt(gc_pause_n);
    var rank: u64 = @intFromFloat(@ceil(q * n));
    rank = std.math.clamp(rank, 1, gc_pause_n);
    var seen: u64 = 0;
    for (gc_pause_hist, 0..) |count, i| {
        seen += count;
        if (seen >= rank) return @intCast(@min(pauseBucketTop(i), gc_pause_max));
    }
    return @intCast(gc_pause_max);
}

extern "c" fn clock_gettime_nsec_np(clock_id: c.clockid_t) u64;

pub export fn rt_nanos() i64 {
    if (comptime builtin.os.tag == .macos) {
        const nsec = clock_gettime_nsec_np(.UPTIME_RAW);
        if (nsec == 0) c.abort();
        return @intCast(nsec);
    } else {
        var ts: c.timespec = .{ .sec = 0, .nsec = 0 };
        if (c.clock_gettime(.MONOTONIC, &ts) != 0) c.abort();
        return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
    }
}

pub export fn rt_panic(msg: [*:0]const u8) noreturn {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "Exception in thread \"main\" java.lang.IllegalStateException: {s}\n", .{std.mem.span(msg)}) catch {
        c.abort();
    };
    _ = c.write(2, line.ptr, line.len);
    c.exit(1);
}

pub export fn rt_gc_note_pause(pause_ns: i64) void {
    const v: u64 = if (pause_ns > 0) @intCast(pause_ns) else 0;
    gc_pause_hist[pauseBucket(v)] += 1;
    gc_pause_n += 1;
    if (v > gc_pause_max) gc_pause_max = v;
}

test "pause histogram buckets and percentiles" {
    // buckets tile the range: each starts right after the previous one's top
    var i: usize = 1;
    while (i < PAUSE_BUCKETS) : (i += 1) try std.testing.expectEqual(i, pauseBucket(pauseBucketTop(i - 1) + 1));
    for ([_]u64{ 0, 1, 15, 16, 17, 31, 32, 1000, 123_456_789, std.math.maxInt(i64) }) |v| {
        const b = pauseBucket(v);
        try std.testing.expect(b < PAUSE_BUCKETS);
        try std.testing.expect(pauseBucketTop(b) >= v);
        if (b > 0) try std.testing.expect(pauseBucketTop(b - 1) < v);
    }
    gc_pause_hist = @splat(0);
    gc_pause_n = 0;
    gc_pause_max = 0;
    try std.testing.expectEqual(@as(i64, 0), pausePercentileNs(0.5));
    var k: i64 = 1;
    while (k <= 100) : (k += 1) rt_gc_note_pause(k * 1000); // 1..100 µs
    const p50 = pausePercentileNs(0.5); // exact: 50 µs
    try std.testing.expect(p50 >= 50_000 and p50 <= 50_000 + 50_000 / 16);
    const p99 = pausePercentileNs(0.99); // exact: 99 µs
    try std.testing.expect(p99 >= 99_000 and p99 <= 100_000);
    try std.testing.expectEqual(@as(i64, 100_000), pausePercentileNs(1.0));
}

pub fn oom() noreturn {
    rt_panic("OutOfMemoryError");
}

pub fn malloc(n: usize) *anyopaque {
    return c.malloc(n) orelse oom();
}

pub fn calloc(n: usize) *anyopaque {
    return c.calloc(1, n) orelse oom();
}

/// `n` must be non-zero: realloc(p, 0) may legally return NULL (glibc frees p),
/// which this non-null signature cannot express. Size-0 callers go through
/// `regions.memRealloc` / `rt_gc_mem_realloc`, which handle it.
pub fn realloc(p: ?*anyopaque, n: usize) *anyopaque {
    std.debug.assert(n != 0);
    return c.realloc(p, n) orelse oom();
}

pub fn free(p: ?*anyopaque) void {
    c.free(p);
}
pub fn getenv_i64(name: [*:0]const u8, default_val: i64) i64 {
    const e = c.getenv(name) orelse return default_val;
    if (e[0] == 0) return default_val;
    return std.fmt.parseInt(i64, std.mem.span(e), 10) catch default_val;
}

pub fn getenv_present(name: [*:0]const u8) bool {
    const e = c.getenv(name) orelse return false;
    return e[0] != 0 and e[0] != '0';
}

/// Peak RSS in KiB. Linux `ru_maxrss` is already KiB; Darwin reports bytes.
pub fn peakRssKb() i64 {
    const ru = std.posix.getrusage(c.rusage.SELF);
    if (builtin.os.tag == .macos) return @divTrunc(ru.maxrss, 1024);
    return ru.maxrss;
}
