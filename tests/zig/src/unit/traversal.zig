//! Port of compiler/gc/tests/unit/traversal.c: trial-deletion traversal scratch space and behavior of the
//! perceus / incremental collectors. Linked with traversal_shim.c, which includes the collector and
//! exports the internals (counts, colors, work-list capacity) the C test read directly.
const std = @import("std");
const kx = @import("kx.zig");
const c = kx.c;

extern fn kxt_ref_count(p: ?*anyopaque) u64;
extern fn kxt_color(p: ?*anyopaque) c_int;
extern fn kxt_is_buffered(p: ?*anyopaque) c_int;
extern fn kxt_black() c_int;
extern fn kxt_work_cap() usize;
extern fn kxt_initial_capacity() usize;
extern fn atoll(s: [*:0]const u8) c_longlong;

const FANOUT = 64;
const Node = extern struct { hdr: u64, vt: *c.KxVTab, edges: [FANOUT]?*Node };
var freed: usize = 0;
var released: usize = 0;
var visits: usize = 0;
fn nodeRel(_: ?*anyopaque) callconv(.c) void {
    c.abort(); // All edges in this test are traced.
}
fn nodeFree(p: ?*anyopaque) callconv(.c) void {
    freed += 1;
    c.rt_free_trace(p, @sizeOf(Node));
}
fn nodeRelo(_: ?*anyopaque) callconv(.c) void {
    released += 1;
}
fn nodeTrav(p: ?*anyopaque, visit: c.kx_visit_fn) callconv(.c) void {
    visits += 1;
    const n: *Node = @ptrCast(@alignCast(p));
    for (n.edges) |e| visit.?(e);
}
var node_vt: c.KxVTab = .{ .rel = nodeRel, .trav = nodeTrav, .relo = nodeRelo, .freemem = nodeFree, .cyclic = @ptrFromInt(1) };

fn nodeNew() *Node {
    const n: *Node = @ptrCast(@alignCast(c.rt_alloc_trace(@sizeOf(Node))));
    n.* = .{ .hdr = 0, .vt = &node_vt, .edges = @splat(null) };
    return n;
}
fn edge(from: *Node, slot: usize, to: *Node) void {
    from.edges[slot] = to;
    to.hdr += 1;
}

export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    const req = kx.require;
    const count: usize = if (argc > 1) @intCast(atoll(argv[1])) else 4096;
    req(count >= 3, @src(), "count >= 3");
    const nodes: [*]*Node = @ptrCast(@alignCast(c.malloc(count * @sizeOf(*Node)) orelse {
        req(false, @src(), "nodes");
        unreachable;
    }));
    for (0..count) |i| nodes[i] = nodeNew();
    for (0..count) |i| for (0..FANOUT) |j| edge(nodes[i], j, nodes[(i + 1) % count]);
    // A late external reference restores every internal edge, including duplicates.
    nodes[count - 1].hdr += 1;
    c.rt_cc_possible_root(nodes[0]);
    c.rt_gc_collect();
    req(freed == 0 and released == 0 and visits == 3 * count - 1, @src(), "!freed && !released && visits == 3 * count - 1");
    for (0..count) |i| {
        req(kxt_ref_count(nodes[i]) == @as(u64, FANOUT) + @intFromBool(i == count - 1), @src(), "ref_count(nodes[i]) == FANOUT + (i == count - 1)");
        req(kxt_color(nodes[i]) == kxt_black() and kxt_is_buffered(nodes[i]) == 0, @src(), "color(nodes[i]) == BLACK && !is_buffered(nodes[i])");
    }
    nodes[count - 1].hdr -= 1;
    c.rt_cc_possible_root(nodes[0]);
    c.rt_gc_collect();
    req(freed == count and released == count and visits == 6 * count - 1, @src(), "freed == count && released == count && visits == 6 * count - 1");
    c.free(@ptrCast(nodes));

    // ScanBlack can restore a sibling that Scan has queued but not yet visited.
    const a = nodeNew();
    const b = nodeNew();
    const cc = nodeNew();
    edge(a, 0, b);
    edge(a, 1, cc);
    edge(cc, 0, b);
    edge(b, 0, a);
    cc.hdr += 1;
    c.rt_cc_possible_root(a);
    c.rt_gc_collect();
    req(freed == count and kxt_ref_count(a) == 1 and kxt_ref_count(b) == 2 and kxt_ref_count(cc) == 2, @src(), "freed == count && ref_count(a) == 1 && ref_count(b) == 2 && ref_count(c) == 2");
    req(kxt_color(a) == kxt_black() and kxt_color(b) == kxt_black() and kxt_color(cc) == kxt_black(), @src(), "color(a) == BLACK && color(b) == BLACK && color(c) == BLACK");
    cc.hdr -= 1;
    c.rt_cc_possible_root(cc);
    c.rt_gc_collect();
    req(freed == count + 3 and released == count + 3, @src(), "freed == count + 3 && released == count + 3");

    var stats: c.KxGcStats = undefined;
    c.rt_gc_stats(&stats);
    _ = c.printf("gc=%s work_bytes=%zu pause_total_ns=%lld pause_max_ns=%lld\n", c.rt_gc_name(), kxt_work_cap() * @sizeOf(?*anyopaque), @as(c_longlong, stats.pause_ns_total), @as(c_longlong, stats.pause_ns_max));
    kx.flushStdout();
    // Parallel edges must not multiply the pending work (nor its retained allocation).
    // An explicit size enables benchmarking the old implementation too.
    if (argc == 1) req(kxt_work_cap() <= kxt_initial_capacity(), @src(), "cc_work.cap <= PTR_STACK_INITIAL_CAPACITY");
    _ = c.puts("TRAVERSAL OK");
    return 0;
}
