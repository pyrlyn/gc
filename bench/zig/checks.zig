//! Threshold policy (see README.md):
//!  * epoch "strongly beats" Boehm on a metric when boehm / epoch >= strong_ratio (default 1.5) in the
//!    baseline: there it may regress by up to `allow` (default 5%);
//!  * everywhere else: no regression beyond the baseline (allowance 0);
//!  * on top of both, a measurement `noise` margin (default 3%, set -Dnoise=0 on a quiet machine) and an
//!    absolute slack for sub-millisecond pauses (default 0.1 ms).
//!  * cyclic_garbage epoch peak RSS <= cyclic_rss_target_mib (Boehm, 3.4 MiB) and, if Boehm was measured
//!    in the same run, <= that measured Boehm peak too.
const std = @import("std");
const h = @import("harness.zig");

pub const Policy = struct { strong_ratio: f64, allow: f64, noise: f64, pause_slack_ms: f64, better: f64 };

pub const Verdict = struct { failures: usize = 0, improvements: usize = 0 };

fn one(v: *Verdict, p: Policy, bench: []const u8, metric: []const u8, unit: []const u8, measured: ?f64, base: ?f64, boehm: ?f64, slack: f64) void {
    const m = measured orelse return;
    const b = base orelse return;
    const strong = if (boehm) |bo| b > 0 and bo / b >= p.strong_ratio else false;
    const allowance: f64 = if (strong) p.allow else 0;
    const limit = b * (1 + allowance + p.noise) + slack;
    const delta = if (b > 0) (m / b - 1) * 100 else 0;
    if (m > limit) {
        v.failures += 1;
        std.debug.print(
            "!!! GC REGRESSION [{s}] {s}: epoch {d:.3} {s} > limit {d:.3} {s} (baseline {d:.3}, {d:.1}%; allowed {d:.0}% {s} + {d:.0}% noise{s})\n",
            .{ bench, metric, m, unit, limit, unit, b, delta, allowance * 100, if (strong) "(epoch strongly beats Boehm)" else "(no regression allowed)", p.noise * 100, if (slack > 0) " + abs slack" else "" },
        );
    } else if (m < b * (1 - p.better)) {
        v.improvements += 1;
        std.debug.print("+++ [{s}] {s}: epoch {d:.3} {s}, {d:.1}% vs baseline {d:.3}: notably better, refresh baselines (`zig build update-baselines`) once this lands\n", .{ bench, metric, m, unit, delta, b });
    } else {
        std.debug.print("ok  [{s}] {s}: epoch {d:.3} {s} (baseline {d:.3}, {d:.1}%, limit {d:.3})\n", .{ bench, metric, m, unit, b, delta, limit });
    }
}

pub fn check(p: Policy, bs: h.Baselines, b: h.Bench, m: h.Measured, boehm_measured: ?h.Measured) Verdict {
    var v: Verdict = .{};
    one(&v, p, b.name, "time", "ms", m.time_ms, b.epoch.time_ms, b.boehm.time_ms, 0);
    if (b.kind == .micro) {
        one(&v, p, b.name, "peak RSS", "MiB", m.rss_mib, b.epoch.rss_mib, b.boehm.rss_mib, 0);
        one(&v, p, b.name, "max pause", "ms", m.pause_max_ms, b.epoch.pause_max_ms, b.boehm.pause_max_ms, p.pause_slack_ms);
    }
    if (std.mem.eql(u8, b.name, "cyclic_garbage")) {
        var target = bs.cyclic_rss_target_mib;
        if (boehm_measured) |bm| target = @min(target, bm.rss_mib * (1 + p.noise));
        if (m.rss_mib > target) {
            v.failures += 1;
            std.debug.print(
                "!!! GC TARGET NOT MET [cyclic_garbage] peak RSS: epoch {d:.2} MiB > Boehm target {d:.2} MiB (baseline file {d:.2}{s}{d:.2}). " ++
                    "EXPECTED to fail on main until the epoch cyclic-garbage branch lands (main after #147: 4.1 MiB).\n",
                .{ m.rss_mib, target, bs.cyclic_rss_target_mib, if (boehm_measured != null) ", Boehm measured now " else "", if (boehm_measured) |bm| bm.rss_mib else 0 },
            );
        } else if (m.rss_mib < bs.cyclic_rss_target_mib * (1 - p.better)) {
            v.improvements += 1;
            std.debug.print("+++ [cyclic_garbage] peak RSS {d:.2} MiB is well below the {d:.2} MiB target: refresh baselines once this lands\n", .{ m.rss_mib, bs.cyclic_rss_target_mib });
        } else std.debug.print("ok  [cyclic_garbage] peak RSS target: epoch {d:.2} MiB <= {d:.2} MiB\n", .{ m.rss_mib, target });
    }
    return v;
}
