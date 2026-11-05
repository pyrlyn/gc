//! Standalone host for symbols `kxgc.h` says the runtime provides.
//! KotlinX supplies these from `compiler/runtime/runtime.c`. This file is the
//! Linux/Zig equivalent used by native tests and benches (CLOCK_MONOTONIC).
const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
});

pub export var rt_rel_draining: c_int = 0;
pub export var rt_relo_owner: c_int = 0;
pub export threadlocal var rt_trav_mode: c_int = 0;

var gc_pauses: [*]i64 = undefined;
var gc_pauses_len: usize = 0;
var gc_pauses_cap: usize = 0;

pub export fn rt_nanos() i64 {
    var ts: c.timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) c.abort();
    return @as(i64, ts.tv_sec) * 1_000_000_000 + @as(i64, ts.tv_nsec);
}

pub export fn rt_panic(msg: [*:0]const u8) noreturn {
    _ = c.fflush(c.stdout);
    _ = c.fprintf(c.stderr, "Exception in thread \"main\" java.lang.IllegalStateException: %s\n", msg);
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
    const p = c.malloc(n) orelse oom();
    return p;
}

pub fn calloc(n: usize) *anyopaque {
    const p = c.calloc(1, n) orelse oom();
    return p;
}

pub fn realloc(p: ?*anyopaque, n: usize) *anyopaque {
    const q = c.realloc(p, n) orelse if (n == 0) unreachable else oom();
    return q;
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
