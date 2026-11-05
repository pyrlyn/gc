//! Process and file helpers for the Zig GC test suite (libc only; no std.fs / std.process, whose APIs
//! move between Zig releases). Mirrors the shell redirections compiler/gc/tests/run.sh used.
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn fork() c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup2(a: c_int, b: c_int) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn setpgid(pid: c_int, pgid: c_int) c_int;
extern "c" fn usleep(us: c_uint) c_int;
extern "c" fn time(t: ?*i64) i64;
const WNOHANG: c_int = 1;
const SIGKILL: c_int = 9;
/// Status run() returns when the command hit Cmd.timeout_s (as timeout(1) reports it).
pub const TIMEOUT: u8 = 124;
/// Timeout for commands that do not set their own (the runner sets it from KX_GC_TEST_TIMEOUT); 0 = none.
pub var default_timeout_s: u32 = 0;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = if (builtin.os.tag == .linux) 0o100 else 0x200;
const O_TRUNC: c_int = if (builtin.os.tag == .linux) 0o1000 else 0x400;
const O_APPEND: c_int = if (builtin.os.tag == .linux) 0o2000 else 0x8;

pub const gpa = std.heap.c_allocator;

pub fn z(s: []const u8) [*:0]const u8 {
    return (gpa.dupeSentinel(u8, s, 0) catch @panic("oom")).ptr;
}
pub fn fmt(comptime f: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(gpa, f, args) catch @panic("oom");
}
pub fn out(comptime f: []const u8, args: anytype) void {
    const s = fmt(f, args);
    _ = write(1, s.ptr, s.len);
}
pub fn env(name: []const u8) ?[]const u8 {
    return if (getenv(z(name))) |v| std.mem.span(v) else null;
}
pub fn exists(path: []const u8) bool {
    return access(z(path), 0) == 0;
}
pub fn executable(path: []const u8) bool {
    return access(z(path), 1) == 0;
}
pub fn mkdirP(path: []const u8) void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) if (i == path.len or path[i] == '/') {
        _ = mkdir(z(path[0..i]), 0o755);
    };
}

/// Where a child stream goes. `.file` truncates, `.append` appends (2>>), `.stdout` is 2>&1.
pub const Sink = union(enum) { null, file: []const u8, append: []const u8, stdout, inherit };

pub const Cmd = struct {
    argv: []const []const u8,
    /// "K=V" entries set in the child (on top of the inherited environment).
    env: []const []const u8 = &.{},
    stdout: Sink = .null,
    stderr: Sink = .null,
    /// Seconds before the command (and its process group) is killed and run() returns TIMEOUT;
    /// 0 = default_timeout_s.
    timeout_s: u32 = 0,
};

fn redirect(s: Sink, fd: c_int) void {
    switch (s) {
        .inherit => {},
        .stdout => _ = dup2(1, fd),
        .null => {
            const f = open("/dev/null", O_WRONLY);
            _ = dup2(f, fd);
        },
        .file, .append => |p| {
            const flags = O_WRONLY | O_CREAT | (if (s == .file) O_TRUNC else O_APPEND);
            const f = open(z(p), flags, @as(c_int, 0o644));
            if (f < 0) _exit(126);
            _ = dup2(f, fd);
            _ = close(f);
        },
    }
}

/// Runs the command and returns the exit status as the shell reports it ($?): code, or 128+signal.
pub fn run(cmd: Cmd) u8 {
    const argv = gpa.alloc(?[*:0]const u8, cmd.argv.len + 1) catch @panic("oom");
    for (cmd.argv, 0..) |a, i| argv[i] = z(a);
    argv[cmd.argv.len] = null;
    const limit = if (cmd.timeout_s > 0) cmd.timeout_s else default_timeout_s;
    const pid = fork();
    if (pid < 0) return 127;
    if (pid == 0) {
        if (limit > 0) _ = setpgid(0, 0); // own group: a hung test's children die with it
        for (cmd.env) |e| {
            const eq = std.mem.indexOfScalar(u8, e, '=').?;
            _ = setenv(z(e[0..eq]), z(e[eq + 1 ..]), 1);
        }
        redirect(cmd.stdout, 1);
        redirect(cmd.stderr, 2);
        _ = execvp(argv[0].?, @ptrCast(argv.ptr));
        _exit(127);
    }
    var st: c_int = 0;
    if (limit > 0) {
        const deadline = time(null) + limit;
        while (waitpid(pid, &st, WNOHANG) == 0) {
            if (time(null) >= deadline) {
                _ = kill(-pid, SIGKILL);
                _ = kill(pid, SIGKILL);
                _ = waitpid(pid, &st, 0);
                out("TIMEOUT {s} after {d}s\n", .{ cmd.argv[0], limit });
                return TIMEOUT;
            }
            _ = usleep(10_000);
        }
    } else _ = waitpid(pid, &st, 0);
    const s: u32 = @bitCast(st);
    if (s & 0x7f == 0) return @truncate((s >> 8) & 0xff);
    return @truncate(128 + (s & 0x7f));
}

/// Like $(cmd): stdout (plus stderr when `merge`) with trailing newlines removed, and the status.
pub const Captured = struct { text: []const u8, status: u8 };
pub fn capture(cmd: Cmd, tmp: []const u8, merge: bool) Captured {
    var c = cmd;
    c.stdout = .{ .file = tmp };
    if (merge) c.stderr = .stdout;
    const status = run(c);
    return .{ .text = trimNl(readFile(tmp)), .status = status };
}

pub fn readFile(path: []const u8) []const u8 {
    const f = open(z(path), O_RDONLY);
    if (f < 0) return "";
    defer _ = close(f);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = read(f, &chunk, chunk.len);
        if (n <= 0) break;
        buf.appendSlice(gpa, chunk[0..@intCast(n)]) catch @panic("oom");
    }
    return buf.items;
}
pub fn writeFile(path: []const u8, data: []const u8) void {
    const f = open(z(path), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (f < 0) return;
    _ = write(f, data.ptr, data.len);
    _ = close(f);
}

pub fn trimNl(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\n");
}

/// `head -n N` of the concatenation of files (missing files skipped), printed to stdout.
pub fn head(paths: []const []const u8, n: usize) void {
    var all: std.ArrayList(u8) = .empty;
    for (paths) |p| all.appendSlice(gpa, readFile(p)) catch @panic("oom");
    var left = n;
    var i: usize = 0;
    while (left > 0 and i < all.items.len) : (left -= 1) {
        const e = if (std.mem.indexOfScalarPos(u8, all.items, i, '\n')) |x| x + 1 else all.items.len;
        out("{s}", .{all.items[i..e]});
        i = e;
    }
}

/// `grep -oE '<prefix>[0-9.]+<mid>[0-9]+' | grep -oE '[0-9]+$'`: the integer after `mid` in the first
/// occurrence of `prefix` NUMBER `mid` NUMBER.
pub fn numAfterPair(s: []const u8, prefix: []const u8, mid: []const u8) ?i64 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, prefix)) |at| {
        from = at + 1;
        var e = at + prefix.len;
        const n0 = e;
        while (e < s.len and (std.ascii.isDigit(s[e]) or s[e] == '.')) e += 1;
        if (e == n0 or !std.mem.startsWith(u8, s[e..], mid)) continue;
        e += mid.len;
        const d0 = e;
        while (e < s.len and std.ascii.isDigit(s[e])) e += 1;
        if (e > d0) return std.fmt.parseInt(i64, s[d0..e], 10) catch null;
    }
    return null;
}

/// The lines of `s` starting with `prefix` (grep '^prefix'), joined with newlines.
pub fn grepPrefix(s: []const u8, prefix: []const u8) []const u8 {
    var res: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| if (std.mem.startsWith(u8, line, prefix)) {
        if (res.items.len > 0) res.append(gpa, '\n') catch @panic("oom");
        res.appendSlice(gpa, line) catch @panic("oom");
    };
    return res.items;
}

/// Splits a shell word list on whitespace, removing one level of single quotes (enough for config.sh output).
pub fn words(s: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_q = false;
    var have = false;
    for (s) |ch| {
        if (ch == '\'') {
            in_q = !in_q;
            have = true;
        } else if (!in_q and std.ascii.isWhitespace(ch)) {
            if (have) list.append(gpa, cur.toOwnedSlice(gpa) catch @panic("oom")) catch @panic("oom");
            have = false;
        } else {
            cur.append(gpa, ch) catch @panic("oom");
            have = true;
        }
    }
    if (have) list.append(gpa, cur.toOwnedSlice(gpa) catch @panic("oom")) catch @panic("oom");
    return list.items;
}

/// The digits right after `key` in `s` (like `grep -oE 'key[0-9]+' | grep -oE '[0-9]+$'`, first match).
pub fn numAfter(s: []const u8, key: []const u8) ?i64 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, key)) |at| {
        var e = at + key.len;
        while (e < s.len and std.ascii.isDigit(s[e])) e += 1;
        if (e > at + key.len) return std.fmt.parseInt(i64, s[at + key.len .. e], 10) catch null;
        from = at + 1;
    }
    return null;
}

test "words handles config.sh quoting" {
    const w = words("-I'/a b/include' -L'/x' -lgc");
    try std.testing.expectEqual(@as(usize, 3), w.len);
    try std.testing.expectEqualStrings("-I/a b/include", w[0]);
    try std.testing.expectEqualStrings("-lgc", w[2]);
}
test "numAfter" {
    try std.testing.expectEqual(@as(?i64, 12), numAfter("x qmax=12 y", "qmax="));
    try std.testing.expectEqual(@as(?i64, 7), numAfter("mem MiB slabs=1.5 logs=7", "logs="));
    try std.testing.expectEqual(@as(?i64, null), numAfter("qmax=", "qmax="));
}
test "numAfterPair" {
    try std.testing.expectEqual(@as(?i64, 7), numAfterPair("logs=3 mem MiB slabs=1.5 logs=7", "mem MiB slabs=", " logs="));
    try std.testing.expectEqual(@as(?i64, 5), numAfterPair("freed paced=9 boundary=5", "freed paced=", " boundary="));
}
