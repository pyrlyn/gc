//! Shared pieces of the Zig GC unit tests: the C interface (kxgc.h via @cImport), libc output, a CHECK
//! counter and the capability arguments the runner passes (they were #ifdef KX_CAP_* in the C tests).
const std = @import("std");
pub const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("kxgc.h");
});
pub const CNT_MASK: u64 = 0xffffffff;
pub const COLOR_SHIFT: u6 = 32;
pub const BUF_BIT: u64 = 1 << 34;

pub var fails: c_int = 0;

/// CHECK(c) of the C tests: report "FAIL <file>:<line>: <what>" on stderr and count, keep going.
pub fn check(ok: bool, src: std.builtin.SourceLocation, what: [*:0]const u8) void {
    if (!ok) {
        _ = c.fprintf(stderrFile(), "FAIL %s:%d: %s\n", src.file.ptr, @as(c_int, @intCast(src.line)), what);
        fails += 1;
    }
}
/// assert() of the C tests: print and abort.
pub fn require(ok: bool, src: std.builtin.SourceLocation, what: [*:0]const u8) void {
    if (!ok) {
        _ = c.fprintf(stderrFile(), "%s:%d: assertion failed: %s\n", src.file.ptr, @as(c_int, @intCast(src.line)), what);
        c.abort();
    }
}

extern "c" var __stderrp: *c.FILE; // macOS
extern "c" var __stdoutp: *c.FILE;
pub fn stderrFile() *c.FILE {
    return __stderrp;
}
pub fn flushStdout() void {
    _ = c.fflush(__stdoutp);
}

pub const Caps = struct { cycles: bool = false, precise: bool = false, deferred: bool = false };
pub fn caps(argc: c_int, argv: [*]const [*:0]const u8, first: usize) Caps {
    var r: Caps = .{};
    var i: usize = first;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "cycles")) r.cycles = true;
        if (std.mem.eql(u8, a, "precise")) r.precise = true;
        if (std.mem.eql(u8, a, "deferred")) r.deferred = true;
    }
    return r;
}
