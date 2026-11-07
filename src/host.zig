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

var gc_pauses: [*]i64 = undefined;
var gc_pauses_len: usize = 0;
var gc_pauses_cap: usize = 0;

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
    if (gc_pauses_len == gc_pauses_cap) {
        const cap = if (gc_pauses_cap == 0) @as(usize, 1024) else gc_pauses_cap * 2;
        const raw = c.realloc(if (gc_pauses_cap == 0) null else @ptrCast(gc_pauses), cap * @sizeOf(i64));
        if (raw == null) return;
        gc_pauses = @ptrCast(@alignCast(raw.?));
        gc_pauses_cap = cap;
    }
    gc_pauses[gc_pauses_len] = pause_ns;
    gc_pauses_len += 1;
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

pub fn realloc(p: ?*anyopaque, n: usize) *anyopaque {
    return c.realloc(p, n) orelse if (n == 0) unreachable else oom();
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
