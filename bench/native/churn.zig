//! Random churn: `live` objects, then `iters` times a random one is freed and replaced, as an LRU cache
//! or a map with eviction does. The other benches free in allocation order or into the current page.
//!   gc-churn-<gc> [live=65536] [iters=10000000]
const std = @import("std");
const gc = @import("collector");
const host = @import("host");

const SIZE: i64 = 40;

fn arg(argv: []const [*:0]const u8, i: usize, default: usize) !usize {
    return if (argv.len > i) std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) else default;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    const live = try arg(argv, 1, 65536);
    const iters = try arg(argv, 2, 10_000_000);
    if (live == 0) return error.InvalidArgument;
    const slots: [*]*u64 = @ptrCast(@alignCast(gc.rt_gc_mem_alloc(@sizeOf(*u64) * live).?));
    for (slots[0..live], 0..) |*s, i| {
        s.* = @ptrCast(@alignCast(gc.allocTrace(SIZE).?));
        s.*.* = i; // first word, like an object header
    }
    var x: u64 = 0x9e3779b97f4a7c15;
    var sum: u64 = 0;
    const t0 = host.rt_nanos();
    for (0..iters) |_| {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        const i: usize = @intCast(x % live);
        // The replacement first: freeing first would let the compiler fold the free and the
        // allocation that pops the same block into nothing. This way each allocation pops the block
        // freed one iteration earlier, at a random place in the heap.
        const o: *u64 = @ptrCast(@alignCast(gc.allocTrace(SIZE).?));
        o.* = i;
        sum +%= slots[i].*; // the release reads the object, as a count decrement would
        gc.freeTrace(slots[i], SIZE);
        slots[i] = o;
    }
    const ns: f64 = @floatFromInt(host.rt_nanos() - t0);
    _ = std.c.printf("%s churn ns_per_op %.2f live %zu sum %llu peak_rss_kb %lld\n", gc.rt_gc_name(), ns / @as(f64, @floatFromInt(iters)), live, @as(c_ulonglong, sum), @as(c_longlong, host.peakRssKb()));
}
