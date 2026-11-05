//! Shared harness for the KotlinX GC regression benchmarks: compiles a KotlinX benchmark program with
//! bin/newkotlinc for one `--gc`, runs it N times (fork/execve, wait4 rusage for peak RSS), times every run
//! with a monotonic Timer, and parses the program's `nanos=` and the collector's `gc-stats:` line
//! (KX_GC_STATS=1). Zig std + libc only.
const std = @import("std");
const c = std.c;
const builtin = @import("builtin");

pub const Kind = enum { micro, suite };
pub const Metrics = struct { time_ms: ?f64 = null, rss_mib: ?f64 = null, pause_max_ms: ?f64 = null };
pub const Bench = struct {
    name: []const u8,
    category: []const u8,
    kind: Kind,
    /// Relative to the repository root.
    source: []const u8,
    epoch: Metrics,
    boehm: Metrics,
};
pub const Baselines = struct {
    provenance: []const u8,
    /// cyclic_garbage epoch peak RSS must be at or below this (Boehm's measured peak), MiB.
    cyclic_rss_target_mib: f64,
    benches: []const Bench,
};

extern "c" fn fork() c_int;
extern "c" fn wait4(pid: c.pid_t, status: ?*c_int, options: c_int, ru: ?*c.rusage) c.pid_t;
extern "c" fn clock_gettime(clk: c_int, tp: *c.timespec) c_int;
extern "c" fn getloadavg(avg: [*]f64, n: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" var environ: [*:null]?[*:0]u8;

const CLOCK_MONOTONIC: c_int = if (builtin.os.tag == .linux) 1 else 6;

/// Monotonic timer (std.time.Timer was removed from std in Zig 0.16+; same semantics).
pub const Timer = struct {
    start_ns: u64,
    fn now() u64 {
        var ts: c.timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    pub fn start() Timer {
        return .{ .start_ns = now() };
    }
    pub fn read(self: Timer) u64 {
        return now() - self.start_ns;
    }
};

pub fn loadAvg() [3]f64 {
    var l: [3]f64 = .{ 0, 0, 0 };
    _ = getloadavg(&l, 3);
    return l;
}

pub const RunResult = struct {
    wall_ms: f64,
    /// The program's own kernel time (`nanos=`), what bench/gc/micro.sh and nkbench.sh report.
    kernel_ms: ?f64,
    rss_mib: f64,
    pause_max_ms: ?f64,
    exit_ok: bool,
    output: []u8,
};

fn z(a: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    return (try a.dupeSentinel(u8, s, 0)).ptr;
}

/// Runs argv (argv[0] is a path) with extra "K=V" env entries; stdout+stderr captured together.
pub fn spawn(a: std.mem.Allocator, argv: []const []const u8, extra_env: []const []const u8, cwd: ?[]const u8) !RunResult {
    const cargv = try a.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |s, i| cargv[i] = try z(a, s);
    cargv[argv.len] = null;
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    for (extra_env) |e| try env.append(a, try z(a, e));
    var i: usize = 0;
    while (environ[i]) |e| : (i += 1) try env.append(a, e);
    try env.append(a, null);
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(env.items.ptr);
    const cargv_p: [*:null]const ?[*:0]const u8 = @ptrCast(cargv.ptr);
    const cwd_z: ?[*:0]const u8 = if (cwd) |d| try z(a, d) else null;

    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    const t = Timer.start();
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.dup2(fds[1], 1);
        _ = c.dup2(fds[1], 2);
        _ = close(fds[0]);
        _ = close(fds[1]);
        if (cwd_z) |d| _ = chdir(d);
        _ = c.execve(cargv_p[0].?, cargv_p, envp);
        c._exit(127);
    }
    _ = close(fds[1]);
    var out: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fds[0], &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(a, buf[0..@intCast(n)]);
    }
    _ = close(fds[0]);
    var status: c_int = 0;
    var ru: c.rusage = std.mem.zeroes(c.rusage);
    _ = wait4(pid, &status, 0, &ru);
    const wall = @as(f64, @floatFromInt(t.read())) / 1e6;
    // ru_maxrss: bytes on macOS, KiB on Linux.
    const rss_bytes: f64 = @as(f64, @floatFromInt(ru.maxrss)) * (if (builtin.os.tag == .linux) 1024.0 else 1.0);
    return .{
        .wall_ms = wall,
        .kernel_ms = if (field(out.items, "nanos=")) |ns| ns / 1e6 else null,
        .rss_mib = rss_bytes / (1024.0 * 1024.0),
        .pause_max_ms = statsField(out.items, "pause_max="),
        .exit_ok = status == 0,
        .output = out.items,
    };
}

fn field(out: []const u8, key: []const u8) ?f64 {
    const at = std.mem.lastIndexOf(u8, out, key) orelse return null;
    var end = at + key.len;
    while (end < out.len and (std.ascii.isDigit(out[end]) or out[end] == '.')) end += 1;
    return std.fmt.parseFloat(f64, out[at + key.len .. end]) catch null;
}

fn statsField(out: []const u8, key: []const u8) ?f64 {
    const at = std.mem.lastIndexOf(u8, out, "gc-stats:") orelse return null;
    return field(out[at..], key);
}

pub const Config = struct {
    root: []const u8,
    runs: usize,
};

pub const Measured = struct { time_ms: f64, wall_ms: f64, rss_mib: f64, pause_max_ms: ?f64, runs: usize };

fn median(a: std.mem.Allocator, xs: []const f64) !f64 {
    const v = try a.dupe(f64, xs);
    std.mem.sort(f64, v, {}, std.sort.asc(f64));
    return if (v.len % 2 == 1) v[v.len / 2] else (v[v.len / 2 - 1] + v[v.len / 2]) / 2;
}

/// Compiles `b.source` for `gc` and measures it: one warm-up run, then `cfg.runs` runs with KX_GC_STATS=1.
/// Every metric is the median over the runs.
pub fn measure(a: std.mem.Allocator, cfg: Config, b: Bench, gc: []const u8) !Measured {
    const out_dir = try std.fmt.allocPrint(a, "{s}/compiler/build/zigbench", .{cfg.root});
    _ = std.c.mkdir(try z(a, out_dir), 0o755);
    const exe = try std.fmt.allocPrint(a, "{s}/{s}.{s}", .{ out_dir, gc, b.name });
    const nkc = try std.fmt.allocPrint(a, "{s}/bin/newkotlinc", .{cfg.root});
    const src = try std.fmt.allocPrint(a, "{s}/{s}", .{ cfg.root, b.source });
    const gcflag = try std.fmt.allocPrint(a, "--gc={s}", .{gc});
    // Boehm is a benchmark-only baseline from bench/gc/third_party/boehm, reachable through bench/gc/gcdir.sh.
    var env: []const []const u8 = &.{};
    if (std.mem.eql(u8, gc, "boehm")) {
        const gd = try spawn(a, &.{ "/bin/sh", try std.fmt.allocPrint(a, "{s}/bench/gc/gcdir.sh", .{cfg.root}) }, &.{}, cfg.root);
        if (!gd.exit_ok) return error.GcDirFailed;
        env = &.{try std.fmt.allocPrint(a, "NEWKOTLIN_GC_DIR={s}/compiler/build/bench-gc-dir", .{cfg.root})};
    }
    const comp = try spawn(a, &.{ nkc, gcflag, src, "-o", exe }, env, cfg.root);
    if (!comp.exit_ok) {
        std.debug.print("\n[{s}] compiling {s} with {s} FAILED:\n{s}\n", .{ b.name, src, gcflag, comp.output });
        return error.CompileFailed;
    }
    // Suite cases read bench/data relative to bench/ (as nkbench.sh runs them).
    const run_cwd = try std.fmt.allocPrint(a, "{s}/bench", .{cfg.root});
    _ = try spawn(a, &.{exe}, &.{}, run_cwd); // warm-up
    const ts = try a.alloc(f64, cfg.runs);
    const ws = try a.alloc(f64, cfg.runs);
    const rs = try a.alloc(f64, cfg.runs);
    const ps = try a.alloc(f64, cfg.runs);
    var have_pause = true;
    for (0..cfg.runs) |i| {
        const r = try spawn(a, &.{exe}, &.{"KX_GC_STATS=1"}, run_cwd);
        if (!r.exit_ok) {
            std.debug.print("\n[{s}] {s} run failed:\n{s}\n", .{ b.name, gc, r.output });
            return error.RunFailed;
        }
        ts[i] = r.kernel_ms orelse r.wall_ms;
        ws[i] = r.wall_ms;
        rs[i] = r.rss_mib;
        if (r.pause_max_ms) |p| ps[i] = p else have_pause = false;
    }
    return .{
        .time_ms = try median(a, ts),
        .wall_ms = try median(a, ws),
        .rss_mib = try median(a, rs),
        .pause_max_ms = if (have_pause) try median(a, ps) else null,
        .runs = cfg.runs,
    };
}

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

/// `explicit` if non-empty, else the nearest parent of the cwd that contains bin/newkotlinc.
pub fn repoRoot(a: std.mem.Allocator, explicit: []const u8) ![]const u8 {
    if (explicit.len > 0) return explicit;
    var buf: [4096]u8 = undefined;
    const cwd = getcwd(&buf, buf.len) orelse return error.NoCwd;
    var dir: []const u8 = std.mem.span(cwd);
    while (true) {
        const probe = try std.fmt.allocPrintSentinel(a, "{s}/bin/newkotlinc", .{dir}, 0);
        if (access(probe.ptr, 1) == 0) return a.dupe(u8, dir);
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return error.RepoRootNotFound;
        if (slash == 0) return error.RepoRootNotFound;
        dir = dir[0..slash];
    }
}

pub fn findBench(bs: Baselines, name: []const u8) ?Bench {
    for (bs.benches) |b| if (std.mem.eql(u8, b.name, name)) return b;
    return null;
}
