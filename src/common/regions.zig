//! RC and tracing regions. Faithful port of `common/regions.inc` (non-leak-check path).
const std = @import("std");
const kx = @import("kxgc");
const host = @import("host");

const RT_CLASSES: usize = 32;
const RT_SIZE_CLASS_SHIFT: u6 = 3;
const RT_SLAB_BYTES: usize = 1 << 16;

const Pool = struct {
    free_list: [RT_CLASSES + 1]?*anyopaque = @splat(null),
    ptr: [*]u8 = undefined,
    end: [*]u8 = undefined,
    inited: bool = false,

    inline fn alloc(self: *Pool, size: i64) *anyopaque {
        const cls = (@as(usize, @intCast(size)) + 7) >> RT_SIZE_CLASS_SHIFT;
        if (cls > RT_CLASSES) return host.malloc(@intCast(size));
        if (self.free_list[cls]) |p| {
            const next: *?*anyopaque = @ptrCast(@alignCast(p));
            self.free_list[cls] = next.*;
            return p;
        }
        const bytes = cls << RT_SIZE_CLASS_SHIFT;
        if (!self.inited or @intFromPtr(self.ptr) + bytes > @intFromPtr(self.end)) {
            const slab: [*]u8 = @ptrCast(host.malloc(RT_SLAB_BYTES));
            self.ptr = slab;
            self.end = slab + RT_SLAB_BYTES;
            self.inited = true;
        }
        const p: *anyopaque = @ptrCast(self.ptr);
        self.ptr += bytes;
        return p;
    }

    inline fn free(self: *Pool, p: *anyopaque, size: i64) void {
        const cls = (@as(usize, @intCast(size)) + 7) >> RT_SIZE_CLASS_SHIFT;
        if (cls > RT_CLASSES) {
            host.free(p);
            return;
        }
        const next: *?*anyopaque = @ptrCast(@alignCast(p));
        next.* = self.free_list[cls];
        self.free_list[cls] = p;
    }
};

var trace_pool = Pool{};

pub fn rtAlloc(size: i64) *anyopaque {
    return host.malloc(@intCast(size));
}

pub fn rtFree(p: ?*anyopaque, size: i64) void {
    _ = size;
    host.free(p);
}

pub inline fn rtAllocTrace(size: i64) *anyopaque {
    return trace_pool.alloc(size);
}

pub inline fn rtFreeTrace(p: ?*anyopaque, size: i64) void {
    if (p) |q| trace_pool.free(q, size);
}

// C regions.inc: NULL is a valid result for n == 0 (malloc(0) / realloc(p, 0) may return
// it); only a failed non-empty request is OutOfMemoryError.
pub fn memAlloc(n: usize) ?*anyopaque {
    const p = std.c.malloc(n);
    if (p == null and n != 0) host.oom();
    return p;
}

pub fn memCalloc(n: usize) ?*anyopaque {
    const p = std.c.calloc(1, n);
    if (p == null and n != 0) host.oom();
    return p;
}

pub fn memRealloc(p: ?*anyopaque, n: usize) ?*anyopaque {
    const q = std.c.realloc(p, n);
    if (q == null and n != 0) host.oom();
    return q;
}

pub fn memFree(p: ?*anyopaque) void {
    host.free(p);
}

pub fn notDeferred(what: [*:0]const u8) noreturn {
    host.rt_panic(what);
}

test "pool reuses same size class" {
    const a = rtAllocTrace(32);
    const b = rtAllocTrace(32);
    try std.testing.expect(a != b);
    rtFreeTrace(a, 32);
    const c = rtAllocTrace(32);
    try std.testing.expect(c == a);
    rtFreeTrace(b, 32);
    rtFreeTrace(c, 32);
}
