//! Zig GC test suite driver: the port of compiler/gc/tests/run.sh. Same cases in the same order, same
//! inputs, same assertions and the same PASS/FAIL/SKIP lines, so the two outputs can be diffed
//! (compare.sh). Unit-level tests are Zig objects (src/unit/*.zig, built by build.zig) linked with the
//! runtime and one collector by the same C compiler with the same flags run.sh used; Kotlin-program tests
//! compile tests/kt|epoch|incremental/*.kt with newkotlinc and check output, exit status and debug counters.
//!
//! New tests (not ports) print "gc-api ..." lines; --ported-only skips them.
//! usage: gc-suite --obj DIR [--ported-only | --mt-only] [--coverage DIR]   (cwd: anywhere inside the repository)
//! env:   GCS="perceus boehm" (subset), NKC, NK_CC as in run.sh.
const std = @import("std");
const p = @import("proc.zig");

var fail = false;
var obj_dir: []const u8 = "";
var cov_dir: ?[]const u8 = null;
var ported_only = false;
var mt_only = false;
var cc: []const u8 = "clang";
var nkc: []const u8 = "";
var out: []const u8 = "";

fn has(caps: []const u8, cap: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, caps, " \t\n");
    while (it.next()) |w| if (std.mem.eql(u8, w, cap)) return true;
    return false;
}

fn cat(parts: []const []const []const u8) []const []const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    for (parts) |x| l.appendSlice(p.gpa, x) catch @panic("oom");
    return l.items;
}

/// Coverage instrumentation flags for the C compiler (empty unless --coverage).
fn covFlags() []const []const u8 {
    return if (cov_dir != null) &.{ "-fprofile-instr-generate", "-fcoverage-mapping" } else &.{};
}
/// Environment for running an instrumented binary: one raw profile per process.
fn covEnv(extra: []const []const u8) []const []const u8 {
    const d = cov_dir orelse return extra;
    return cat(&.{ extra, &.{p.fmt("LLVM_PROFILE_FILE={s}/raw/%p-%m.profraw", .{d})} });
}
/// Coverage: keep a copy of every binary that runs (scratch binaries are rebuilt under the same name), so
/// llvm-cov can map each raw profile to the exact binary that wrote it.
var bin_seq: usize = 0;
fn noteBinary(path: []const u8) void {
    const d = cov_dir orelse return;
    if (!p.exists(path)) return;
    bin_seq += 1;
    const base = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0) + 1 ..];
    const keep = p.fmt("{s}/bin/{d:0>4}-{s}", .{ d, bin_seq, base });
    _ = p.run(.{ .argv = &.{ "cp", path, keep } });
    const list = p.fmt("{s}/binaries.txt", .{d});
    p.writeFile(list, p.fmt("{s}{s}\n", .{ p.readFile(list), keep }));
}

fn compileC(args: []const []const u8, err: []const u8) bool {
    return p.run(.{ .argv = cat(&.{ &.{cc}, covFlags(), args }), .stderr = .{ .file = err } }) == 0;
}
/// Per-command timeout (seconds) for every test binary and build step: KX_GC_TEST_TIMEOUT, default 300, 0 disables. A hung test
/// (e.g. a mutant that deadlocks) is killed, reported as TIMEOUT and counts as a failure.
fn testTimeout() u32 {
    const v = p.env("KX_GC_TEST_TIMEOUT") orelse return 300;
    return std.fmt.parseInt(u32, v, 10) catch 300;
}
fn runTo(exe: []const u8, args: []const []const u8, env: []const []const u8, log: p.Sink, err: p.Sink) u8 {
    noteBinary(exe);
    return p.run(.{ .argv = cat(&.{ &.{exe}, args }), .env = covEnv(env), .stdout = log, .stderr = err });
}
fn nk(args: []const []const u8, err: p.Sink) bool {
    var a = args;
    if (cov_dir != null) a = cat(&.{ args, &.{ "--cflags", "-O3 -flto -fprofile-instr-generate -fcoverage-mapping" } });
    return p.run(.{ .argv = cat(&.{ &.{nkc}, a }), .stderr = err }) == 0;
}
/// newkotlinc with explicit --cflags (ASan builds); coverage flags are appended to them.
fn nkCflags(pre: []const []const u8, cflags: []const u8, post: []const []const u8) bool {
    const f = if (cov_dir != null) p.fmt("{s} -fprofile-instr-generate -fcoverage-mapping", .{cflags}) else cflags;
    return p.run(.{ .argv = cat(&.{ &.{nkc}, pre, &.{ "--cflags", f }, post }), .stderr = .null }) == 0;
}

fn failHead(paths: []const []const u8, n: usize) void {
    p.head(paths, n);
    fail = true;
}

fn repoRoot() []const u8 {
    var buf: [4096]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse @panic("getcwd");
    var dir: []const u8 = p.gpa.dupe(u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd)), 0)) catch @panic("oom");
    while (true) {
        if (p.exists(p.fmt("{s}/compiler/gc/kxgc.h", .{dir}))) return dir;
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse @panic("not inside the KotlinX repository");
        if (slash == 0) @panic("not inside the KotlinX repository");
        dir = dir[0..slash];
    }
}

extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn exit(code: c_int) noreturn;
extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn getpid() c_int;

fn listGcs() []const []const u8 {
    if (p.env("GCS")) |g| return p.words(g);
    var names: std.ArrayList([]const u8) = .empty;
    // Same order as the shell glob compiler/gc/*/gc.c (alphabetical).
    const lst = p.capture(.{ .argv = &.{ "/bin/sh", "-c", "for d in compiler/gc/*/gc.c; do basename \"$(dirname \"$d\")\"; done" } }, p.fmt("{s}/gcs.txt", .{out}), false);
    var it = std.mem.tokenizeScalar(u8, lst.text, '\n');
    while (it.next()) |n| names.append(p.gpa, n) catch @panic("oom");
    return names.items;
}

const opts = [_][]const u8{ "-O1", "-O3" };

pub fn main(init: std.process.Init.Minimal) void {
    var args = init.args.iterate();
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--obj")) obj_dir = p.gpa.dupe(u8, args.next().?) catch unreachable //
        else if (std.mem.eql(u8, a, "--coverage")) cov_dir = p.gpa.dupe(u8, args.next().?) catch unreachable //
        else if (std.mem.eql(u8, a, "--ported-only")) ported_only = true //
        else if (std.mem.eql(u8, a, "--mt-only")) mt_only = true //
        else @panic("usage: gc-suite --obj DIR [--ported-only | --mt-only] [--coverage DIR]");
    }
    if (obj_dir.len == 0) @panic("--obj DIR is required");
    const root = repoRoot();
    _ = chdir(p.z(root));
    nkc = p.env("NKC") orelse "compiler/build/newkotlinc.kexe";
    if (!p.executable(nkc)) _ = p.run(.{ .argv = &.{"compiler/build.sh"}, .stderr = .inherit });
    p.default_timeout_s = testTimeout(); // after the compiler build, which may legitimately take long
    cc = p.env("NK_CC") orelse (if (p.executable("/usr/bin/clang")) "/usr/bin/clang" else "clang");
    // A separate scratch dir, so this can run next to run.sh (which owns compiler/build/gc-tmp), and one per
    // process: two concurrent suites sharing it delete and overwrite each other's binaries (rc=126, "compile").
    out = p.fmt("compiler/build/gc-zig-tmp-{d}", .{getpid()});
    _ = p.run(.{ .argv = &.{ "rm", "-rf", out } });
    p.mkdirP(out);
    if (cov_dir) |d| {
        p.mkdirP(p.fmt("{s}/raw", .{d}));
        p.mkdirP(p.fmt("{s}/bin", .{d}));
    }
    const O = obj_dir;
    const gcs = listGcs();
    if (mt_only) {
        mtTests(gcs);
        finish();
    }

    for (gcs) |g| {
        const caps = p.readFile(p.fmt("compiler/gc/{s}/caps", .{g}));
        var extra: []const []const u8 = &.{};
        const cfg = p.fmt("compiler/gc/{s}/config.sh", .{g});
        if (p.exists(cfg)) {
            const r = p.capture(.{ .argv = &.{ "sh", cfg } }, p.fmt("{s}/cfg-{s}", .{ out, g }), false);
            if (r.status != 0) {
                p.out("FAIL gc {s}: config.sh\n", .{g});
                fail = true;
                continue;
            }
            extra = p.words(r.text);
        }
        var def: std.ArrayList([]const u8) = .empty;
        if (has(caps, "cycles")) def.append(p.gpa, "-DKX_CAP_CYCLES") catch unreachable;
        if (has(caps, "precise")) def.append(p.gpa, "-DKX_CAP_PRECISE") catch unreachable;
        // Capabilities reach the Zig unit test as arguments (they were #ifdefs in gc_unit.c).
        var capargs: std.ArrayList([]const u8) = .empty;
        if (has(caps, "cycles")) capargs.append(p.gpa, "cycles") catch unreachable;
        if (has(caps, "precise")) capargs.append(p.gpa, "precise") catch unreachable;
        const gc_c = p.fmt("compiler/gc/{s}/gc.c", .{g});
        const trav_gc = std.mem.eql(u8, g, "perceus") or std.mem.eql(u8, g, "incremental");
        const testdef: []const []const u8 = if (std.mem.eql(u8, g, "incremental")) &.{"-DTEST_INCREMENTAL"} else &.{};

        for (opts) |o| {
            if (has(caps, "deferred")) {
                p.out("SKIP gc-unit {s} {s} (deferred RC)\n", .{ g, o });
                continue;
            }
            const exe = p.fmt("{s}/unit-{s}", .{ out, g });
            const err = p.fmt("{s}/unit-{s}.err", .{ out, g });
            const log = p.fmt("{s}/unit-{s}.log", .{ out, g });
            if (compileC(cat(&.{ &.{ o, "-g", "-Icompiler/gc" }, def.items, extra, &.{ p.fmt("{s}/gc_unit.o", .{O}), "compiler/runtime/runtime.c", gc_c, "-o", exe } }), err) and
                runTo(exe, capargs.items, &.{}, .{ .file = log }, .stdout) == 0)
                p.out("PASS gc-unit {s} {s}\n", .{ g, o })
            else {
                p.out("FAIL gc-unit {s} {s}\n", .{ g, o });
                failHead(&.{ err, log }, 20);
            }
            if (trav_gc) {
                const texe = p.fmt("{s}/traversal-{s}", .{ out, g });
                const terr = p.fmt("{s}/traversal-{s}.err", .{ out, g });
                const tlog = p.fmt("{s}/traversal-{s}.log", .{ out, g });
                if (compileC(cat(&.{ &.{ o, "-g", "-Icompiler/gc" }, testdef, &.{ p.fmt("{s}/traversal.o", .{O}), "compiler/gc/tests/zig/src/unit/traversal_shim.c", "compiler/runtime/runtime.c", "-o", texe } }), terr) and
                    runTo(texe, &.{}, &.{}, .{ .file = tlog }, .stdout) == 0)
                    p.out("PASS gc-traversal {s} {s}\n", .{ g, o })
                else {
                    p.out("FAIL gc-traversal {s} {s}\n", .{ g, o });
                    failHead(&.{ terr, tlog }, 20);
                }
            }
            // New (non-ported) API tests: same build as gc-unit, plus the deferred-RC protocol for epoch below.
            if (!ported_only) apiTest(g, o, def.items, extra, capargs.items, gc_c);
        }
        if (has(caps, "deferred") and !ported_only) for (opts) |o| apiTest(g, o, def.items, extra, cat(&.{ capargs.items, &.{"deferred"} }), gc_c);
        if (trav_gc) {
            const exe = p.fmt("{s}/traversal-{s}.asan", .{ out, g });
            const err = p.fmt("{s}/traversal-{s}.asanerr", .{ out, g });
            const log = p.fmt("{s}/traversal-{s}.asanlog", .{ out, g });
            if (compileC(cat(&.{ &.{ "-O1", "-g", "-fsanitize=address", "-fno-omit-frame-pointer", "-DRT_PLAIN_MALLOC", "-Icompiler/gc" }, testdef, &.{ p.fmt("{s}/traversal.o", .{O}), "compiler/gc/tests/zig/src/unit/traversal_shim.c", "compiler/runtime/runtime.c", "-o", exe } }), err) and
                runTo(exe, &.{}, &.{}, .{ .file = log }, .stdout) == 0)
                p.out("PASS gc-traversal-asan {s}\n", .{g})
            else {
                p.out("FAIL gc-traversal-asan {s}\n", .{g});
                failHead(&.{ err, log }, 20);
            }
        }
        ktTests(g, caps);
    }
    epochTests(gcs);
    incrementalTests(gcs, O);
    // Selecting an unknown implementation is a compile error.
    if (nk(&.{ "--gc=nope", "compiler/gc/tests/kt/reuse.kt", "-o", p.fmt("{s}/nope", .{out}) }, .null)) {
        p.out("FAIL gc-unknown\n", .{});
        fail = true;
    } else p.out("PASS gc-unknown\n", .{});
    if (!ported_only) mtTests(gcs);
    finish();
}

fn finish() noreturn {
    _ = p.run(.{ .argv = &.{ "rm", "-rf", out } });
    if (!fail) p.out("GC ALL PASSED\n", .{}) else {
        p.out("GC FAILED\n", .{});
        exit(1);
    }
    exit(0);
}

/// Multithreaded test (src/unit/mt_test.zig) for collectors with a concurrent collector thread (the
/// "deferred" capability: epoch). The others run entirely on the mutator thread and make no thread-safety
/// claim; they are reported as SKIP. Plain -O1/-O3 builds check the results; the TSan build (-O1,
/// halt_on_error) additionally fails on any data race or mutex misuse inside the collector.
fn mtTests(gcs: []const []const u8) void {
    const env = [_][]const u8{ "KX_GC_EXIT_DRAIN=1", "KX_GC_THREADS=4", "KX_GC_LOG_CAP=256", "KX_GC_MIN_THRESHOLD=16", "KX_GC_MAJOR_RATIO=1" };
    for (gcs) |g| {
        const caps = p.readFile(p.fmt("compiler/gc/{s}/caps", .{g}));
        if (!has(caps, "deferred")) {
            p.out("SKIP gc-mt {s} (no concurrent collector)\n", .{g});
            continue;
        }
        const gc_c = p.fmt("compiler/gc/{s}/gc.c", .{g});
        const tsan_env = "TSAN_OPTIONS=halt_on_error=1:exitcode=66:second_deadlock_stack=1";
        // tiny fixed major steps: an incremental major spans many logs and the idle gaps between turns
        const slow_major = [_][]const u8{ "KX_GC_MAJOR_STEP_US=0", "KX_GC_MAJOR_STEP=64" };
        const variants = [_]struct { name: []const u8, flags: []const []const u8, env: []const []const u8 }{
            .{ .name = "-O1", .flags = &.{ "-O1", "-DKX_GC_LOCK_CHECK" }, .env = &slow_major },
            .{ .name = "-O3", .flags = &.{"-O3"}, .env = &.{} },
            .{ .name = "tsan", .flags = &.{ "-O1", "-fsanitize=thread", "-fno-omit-frame-pointer", "-DRT_PLAIN_MALLOC", "-DKX_GC_LOCK_CHECK" }, .env = &(.{tsan_env} ++ slow_major) },
            // stop-the-world background majors (collector_main's non-incremental path)
            .{ .name = "-O1-stw-major", .flags = &.{ "-O1", "-DKX_GC_LOCK_CHECK" }, .env = &.{"KX_GC_INC_MAJOR=0"} },
            .{ .name = "tsan-stw-major", .flags = &.{ "-O1", "-fsanitize=thread", "-fno-omit-frame-pointer", "-DRT_PLAIN_MALLOC", "-DKX_GC_LOCK_CHECK" }, .env = &.{ tsan_env, "KX_GC_INC_MAJOR=0" } },
        };
        for (variants) |v| {
            const exe = p.fmt("{s}/mt-{s}{s}", .{ out, g, v.name });
            const err = p.fmt("{s}/mt-{s}{s}.err", .{ out, g, v.name });
            const log = p.fmt("{s}/mt-{s}{s}.log", .{ out, g, v.name });
            if (compileC(cat(&.{ v.flags, &.{ "-g", "-Icompiler/gc", p.fmt("{s}/mt_test.o", .{obj_dir}), "compiler/gc/tests/zig/src/unit/mt_shim.c", "compiler/runtime/runtime.c", gc_c, "-o", exe } }), err) and
                runTo(exe, &.{g}, cat(&.{ &env, v.env }), .{ .file = log }, .{ .append = err }) == 0)
                p.out("PASS gc-mt {s} {s}\n", .{ g, v.name })
            else {
                p.out("FAIL gc-mt {s} {s}\n", .{ g, v.name });
                failHead(&.{ err, log }, 30);
            }
        }
    }
}

fn apiTest(g: []const u8, o: []const u8, def: []const []const u8, extra: []const []const u8, capargs: []const []const u8, gc_c: []const u8) void {
    const exe = p.fmt("{s}/api-{s}", .{ out, g });
    const err = p.fmt("{s}/api-{s}.err", .{ out, g });
    const log = p.fmt("{s}/api-{s}.log", .{ out, g });
    if (compileC(cat(&.{ &.{ o, "-g", "-Icompiler/gc" }, def, extra, &.{ p.fmt("{s}/api_test.o", .{obj_dir}), "compiler/runtime/runtime.c", gc_c, "-o", exe } }), err) and
        runTo(exe, cat(&.{ &.{g}, capargs }), &.{"KX_GC_EXIT_DRAIN=1"}, .{ .file = log }, .stdout) == 0)
        p.out("PASS gc-api {s} {s}\n", .{ g, o })
    else {
        p.out("FAIL gc-api {s} {s}\n", .{ g, o });
        failHead(&.{ err, log }, 20);
    }
}

fn ktTests(g: []const u8, caps: []const u8) void {
    const names = p.capture(.{ .argv = &.{ "/bin/sh", "-c", "for t in compiler/gc/tests/kt/*.kt; do basename \"$t\" .kt; done" } }, p.fmt("{s}/kt.txt", .{out}), false);
    var it = std.mem.tokenizeScalar(u8, names.text, '\n');
    while (it.next()) |n| {
        const t = p.fmt("compiler/gc/tests/kt/{s}.kt", .{n});
        const exp = p.trimNl(p.readFile(p.fmt("compiler/gc/tests/kt/{s}.out", .{n})));
        if (std.mem.indexOf(u8, p.readFile(t), "// gc-needs: cycles") != null and lineStarts(p.readFile(t), "// gc-needs: cycles") and !has(caps, "cycles")) {
            p.out("SKIP gc {s} {s} (no cycle collection)\n", .{ g, n });
            continue;
        }
        const exe = p.fmt("{s}/{s}.{s}", .{ out, g, n });
        const err = p.fmt("{s}/{s}.{s}.err", .{ out, g, n });
        var ok = nk(&.{ p.fmt("--gc={s}", .{g}), t, "-o", exe }, .{ .file = err });
        if (ok) {
            noteBinary(exe);
            const r = p.capture(.{ .argv = &.{exe}, .env = covEnv(&.{}) }, p.fmt("{s}.stdout", .{exe}), true);
            ok = std.mem.eql(u8, r.text, exp);
        }
        if (ok) p.out("PASS gc {s} {s}\n", .{ g, n }) else {
            p.out("FAIL gc {s} {s}\n", .{ g, n });
            failHead(&.{err}, 5);
        }
        if (has(caps, "precise")) {
            const lc = p.fmt("{s}.lc", .{exe});
            const lcerr = p.fmt("{s}.lcerr", .{exe});
            _ = nk(&.{ p.fmt("--gc={s}", .{g}), "--leak-check", t, "-o", lc }, .null);
            noteBinary(lc);
            const r = p.capture(.{ .argv = &.{lc}, .env = covEnv(&.{}), .stderr = .{ .file = lcerr } }, p.fmt("{s}.stdout", .{lc}), false);
            if (r.status == 0 and std.mem.eql(u8, r.text, exp) and std.mem.indexOf(u8, p.readFile(lcerr), "leak-check: OK") != null)
                p.out("PASS gc-leaks {s} {s}\n", .{ g, n })
            else {
                p.out("FAIL gc-leaks {s} {s} (rc={d})\n", .{ g, n, r.status });
                // grep -v "live=0" | head
                const e = p.readFile(lcerr);
                var lines = std.mem.splitScalar(u8, e, '\n');
                var k: usize = 0;
                while (lines.next()) |l| if (k < 10 and l.len > 0 and std.mem.indexOf(u8, l, "live=0") == null) {
                    p.out("{s}\n", .{l});
                    k += 1;
                };
                fail = true;
            }
        }
        if (has(caps, "asan")) {
            const ax = p.fmt("{s}.asan", .{exe});
            const aerr = p.fmt("{s}.asanerr", .{exe});
            _ = nkCflags(&.{ p.fmt("--gc={s}", .{g}), "--alloc", "malloc" }, "-O1 -g -fsanitize=address -fno-omit-frame-pointer", &.{ t, "-o", ax });
            noteBinary(ax);
            const r = p.capture(.{ .argv = &.{ax}, .env = covEnv(&.{}), .stderr = .{ .file = aerr } }, p.fmt("{s}.stdout", .{ax}), false);
            if (r.status == 0 and std.mem.eql(u8, r.text, exp)) p.out("PASS gc-asan {s} {s}\n", .{ g, n }) else {
                p.out("FAIL gc-asan {s} {s} (rc={d})\n", .{ g, n, r.status });
                failHead(&.{aerr}, 20);
            }
        }
    }
}

/// grep -q '^prefix'
fn lineStarts(s: []const u8, prefix: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| if (std.mem.startsWith(u8, l, prefix)) return true;
    return false;
}

fn contains(gcs: []const []const u8, g: []const u8) bool {
    for (gcs) |x| if (std.mem.eql(u8, x, g)) return true;
    return false;
}

fn optNum(v: ?i64) []const u8 {
    return if (v) |x| p.fmt("{d}", .{x}) else "";
}

fn epochTests(gcs: []const []const u8) void {
    if (!contains(gcs, "epoch")) return;
    // Epoch: a back-pressure wait over the pause target on every hand-off (KX_GC_TARGET_PAUSE_US=1) must not
    // grow the log queue / log pool without bound: adaptive limit <= 16, at most limit + 2 spare logs.
    {
        const exe = p.fmt("{s}/epoch.queue_spike", .{out});
        if (nk(&.{ "--gc=epoch", "compiler/gc/tests/epoch/queue_spike.kt", "-o", exe }, .null)) {
            noteBinary(exe);
            // dbg=$(... 2>&1 >/dev/null): stderr only.
            const dbgf = p.fmt("{s}.dbg", .{exe});
            _ = p.run(.{ .argv = &.{exe}, .env = covEnv(&.{ "KX_GC_TARGET_PAUSE_US=1", "KX_GC_DEBUG=1" }), .stdout = .null, .stderr = .{ .file = dbgf } });
            const dbg = p.readFile(dbgf);
            const q = p.numAfter(dbg, "qmax=");
            const logs = p.numAfterPair(dbg, "mem MiB slabs=", " logs=");
            if (q != null and logs != null and q.? <= 16 and logs.? <= 20) p.out("PASS gc-epoch queue_spike (qmax={d} logs={d})\n", .{ q.?, logs.? }) else {
                p.out("FAIL gc-epoch queue_spike (qmax={s} logs={s}, want <= 16 / <= 20)\n", .{ optNum(q), optNum(logs) });
                fail = true;
            }
        } else {
            p.out("FAIL gc-epoch queue_spike: compile\n", .{});
            fail = true;
        }
    }
    // Epoch: KX_GC_BOUNDARY_KEEP=16384 frees most dead objects paced by allocations, not at the boundary;
    // both settings free everything (--leak-check) with the same checksum.
    {
        const t = "compiler/gc/tests/epoch/paced_free.kt";
        const want = "checksum=2000001000000";
        const exe = p.fmt("{s}/epoch.paced", .{out});
        const lc = p.fmt("{s}/epoch.paced.lc", .{out});
        if (nk(&.{ "--gc=epoch", t, "-o", exe }, .null) and nk(&.{ "--gc=epoch", "--leak-check", t, "-o", lc }, .null)) {
            noteBinary(exe);
            noteBinary(lc);
            const dbg = p.capture(.{ .argv = &.{exe}, .env = covEnv(&.{ "KX_GC_BOUNDARY_KEEP=16384", "KX_GC_DEBUG=1", "KX_GC_EXIT_DRAIN=1" }) }, p.fmt("{s}.dbg", .{exe}), true).text;
            const got = p.grepPrefix(dbg, "checksum=");
            const pc = p.numAfter(dbg, "freed paced=");
            const bf = p.numAfterPair(dbg, "freed paced=", " boundary=");
            if (std.mem.eql(u8, got, want) and pc != null and bf != null and pc.? > bf.?) p.out("PASS gc-epoch paced_free (paced={d} boundary={d})\n", .{ pc.?, bf.? }) else {
                p.out("FAIL gc-epoch paced_free (got={s} paced={s} boundary={s}, want paced > boundary)\n", .{ got, optNum(pc), optNum(bf) });
                fail = true;
            }
            for ([_][]const u8{ "16384", "0" }) |keep| {
                const lcerr = p.fmt("{s}/epoch.paced.lcerr", .{out});
                const r = p.capture(.{ .argv = &.{lc}, .env = covEnv(&.{p.fmt("KX_GC_BOUNDARY_KEEP={s}", .{keep})}), .stderr = .{ .file = lcerr } }, p.fmt("{s}.stdout", .{lc}), false);
                if (r.status == 0 and std.mem.eql(u8, r.text, want) and std.mem.indexOf(u8, p.readFile(lcerr), "leak-check: OK") != null)
                    p.out("PASS gc-epoch paced_free leaks keep={s}\n", .{keep})
                else {
                    p.out("FAIL gc-epoch paced_free leaks keep={s} (rc={d})\n", .{ keep, r.status });
                    failHead(&.{lcerr}, 10);
                }
            }
        } else {
            p.out("FAIL gc-epoch paced_free: compile\n", .{});
            fail = true;
        }
    }
    // Epoch: freed big blocks are released with madvise (madvised > 0), KX_GC_MADVISE=0 turns it off; both
    // free everything with the same checksum.
    {
        const t = "compiler/gc/tests/epoch/madvise_big.kt";
        const want = "checksum=800000";
        const exe = p.fmt("{s}/epoch.madv", .{out});
        const lc = p.fmt("{s}/epoch.madv.lc", .{out});
        if (nk(&.{ "--gc=epoch", t, "-o", exe }, .null) and nk(&.{ "--gc=epoch", "--leak-check", t, "-o", lc }, .null)) {
            noteBinary(exe);
            noteBinary(lc);
            for ([_][]const u8{ "1", "0" }) |m| {
                const dbg = p.capture(.{ .argv = &.{exe}, .env = covEnv(&.{ p.fmt("KX_GC_MADVISE={s}", .{m}), "KX_GC_DEBUG=1", "KX_GC_EXIT_DRAIN=1" }) }, p.fmt("{s}.dbg", .{exe}), true).text;
                const got = p.grepPrefix(dbg, "checksum=");
                const mv = p.numAfter(dbg, "madvised=");
                var ok = false;
                if (mv) |v| ok = if (std.mem.eql(u8, m, "1")) v > 0 else v == 0;
                if (std.mem.eql(u8, got, want) and ok) p.out("PASS gc-epoch madvise_big madvise={s} (madvised={d})\n", .{ m, mv.? }) else {
                    p.out("FAIL gc-epoch madvise_big madvise={s} (got={s} madvised={s})\n", .{ m, got, optNum(mv) });
                    fail = true;
                }
                const lcerr = p.fmt("{s}/epoch.madv.lcerr", .{out});
                const r = p.capture(.{ .argv = &.{lc}, .env = covEnv(&.{p.fmt("KX_GC_MADVISE={s}", .{m})}), .stderr = .{ .file = lcerr } }, p.fmt("{s}.stdout", .{lc}), false);
                if (r.status == 0 and std.mem.eql(u8, r.text, want) and std.mem.indexOf(u8, p.readFile(lcerr), "leak-check: OK") != null)
                    p.out("PASS gc-epoch madvise_big leaks madvise={s}\n", .{m})
                else {
                    p.out("FAIL gc-epoch madvise_big leaks madvise={s} (rc={d})\n", .{ m, r.status });
                    failHead(&.{lcerr}, 10);
                }
            }
        } else {
            p.out("FAIL gc-epoch madvise_big: compile\n", .{});
            fail = true;
        }
    }
}

fn incrementalTests(gcs: []const []const u8, O: []const u8) void {
    if (!contains(gcs, "incremental")) return;
    // A live root scanned black by an earlier slice must leave the buffer with the step that stopped there
    // (left behind, a later step frees it inside its own release: a double free under ASan).
    {
        const exe = p.fmt("{s}/incremental.slice_black", .{out});
        const err = p.fmt("{s}.err", .{exe});
        if (nkCflags(&.{ "--gc=incremental", "--alloc", "malloc" }, "-O1 -g -fsanitize=address -fno-omit-frame-pointer", &.{ "compiler/gc/tests/incremental/slice_black.kt", "-o", exe })) {
            noteBinary(exe);
            const r = p.capture(.{ .argv = &.{exe}, .env = covEnv(&.{"KX_GC_BUDGET_US=300"}), .stderr = .{ .file = err } }, p.fmt("{s}.stdout", .{exe}), false);
            if (r.status == 0 and std.mem.eql(u8, r.text, "53215861")) p.out("PASS gc-incremental slice_black\n", .{}) else {
                p.out("FAIL gc-incremental slice_black (rc={d})\n", .{r.status});
                failHead(&.{err}, 20);
            }
        } else {
            p.out("FAIL gc-incremental slice_black: compile\n", .{});
            fail = true;
        }
    }
    // A step over budget on its first slice finishes in one pass instead of re-tracing a shared graph per slice.
    {
        const exe = p.fmt("{s}/incremental.one_pass", .{out});
        const err = p.fmt("{s}/incremental.one_pass.err", .{out});
        if (compileC(&.{ "-O1", "-g", "-Icompiler/gc", p.fmt("{s}/one_pass.o", .{O}), "compiler/runtime/runtime.c", "compiler/gc/incremental/gc.c", "-o", exe }, err) and
            runTo(exe, &.{}, &.{"KX_GC_BUDGET_US=0"}, .inherit, .{ .append = err }) == 0)
            p.out("PASS gc-incremental one_pass\n", .{})
        else {
            p.out("FAIL gc-incremental one_pass\n", .{});
            failHead(&.{err}, 20);
        }
    }
}

test {
    _ = p;
}
