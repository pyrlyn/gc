//! Size-class phases: each round allocates `live` objects of one size and then frees them, cycling
//! through sizes from 40 to 256 bytes. Peak memory shows whether memory freed by one size class
//! serves the next: without that, the pool keeps every class's peak at once.
//!   gc-phases-<gc> [live=100000] [rounds=24] [keep_every=0]
//! keep_every=K keeps every K-th object of a round alive to the end, pinning its page.
const std = @import("std");
const gc = @import("collector");
const host = @import("host");

const SIZES = [_]i64{ 40, 64, 96, 128, 200, 256 };

fn arg(argv: []const [*:0]const u8, i: usize, default: usize) !usize {
    return if (argv.len > i) std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) else default;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    const live = try arg(argv, 1, 100_000);
    const rounds = try arg(argv, 2, 24);
    const keep_every = try arg(argv, 3, 0);
    const slots: [*]*u64 = @ptrCast(@alignCast(gc.rt_gc_mem_alloc(@sizeOf(*u64) * live).?));
    var kept: usize = 0;
    const t0 = host.rt_nanos();
    for (0..rounds) |r| {
        const size = SIZES[r % SIZES.len];
        for (slots[0..live], 0..) |*s, i| {
            s.* = @ptrCast(@alignCast(gc.allocTrace(size).?));
            s.*.* = i; // first word, like an object header
        }
        for (slots[0..live], 0..) |s, i| {
            if (keep_every != 0 and i % keep_every == 0) kept += 1 else gc.freeTrace(s, size);
        }
    }
    const ns: f64 = @floatFromInt(host.rt_nanos() - t0);
    _ = std.c.printf("%s phases ns_per_obj %.2f kept %zu peak_rss_kb %lld\n", gc.rt_gc_name(), ns / @as(f64, @floatFromInt(live * rounds)), kept, @as(c_longlong, host.peakRssKb()));
}
