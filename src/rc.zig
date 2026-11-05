//! Plain reference counting, no cycle collector. Port of `rc/gc.c`.
const kx = @import("kxgc");
const host = @import("host");
const regions = @import("common/regions.zig");
const obj = @import("common/object.zig");

pub const name = "rc";
pub const caps = .{ .cycles = false, .precise = true, .asan = true, .deferred = false };

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
pub export fn rt_free_trace(p: ?*anyopaque, size: i64) void {
    regions.rtFreeTrace(p, size);
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
    _ = p;
}
pub export fn rt_cc_dead(p: ?*anyopaque) void {
    const o = p orelse return;
    if (obj.vtab(o).freemem) |f| f(o);
}
pub export fn rt_gc_collect() void {}
pub export fn rt_gc_name() [*:0]const u8 {
    return "rc";
}
pub export fn rt_gc_stats(out: *kx.Stats) void {
    out.* = .{};
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
