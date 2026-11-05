#!/usr/bin/env python3
"""Compare two ops-raw logs (same format as bench/ops and gc-ops).

Each data line: `<collector> <op> <value>`
`peak_rss_kb` is reported separately and ignored in ns/op medians.

Usage:
  python3 scripts/macos/compare.py c-ops-raw.txt zig-ops-raw.txt
  python3 scripts/macos/compare.py --label "local Mac" c.txt zig.txt

Does not execute any command (no subprocess). Prints markdown + raw samples.
"""
from __future__ import annotations

import argparse
import collections
import statistics
import sys
from pathlib import Path


OPS = ("rc_pair", "field_store", "alloc_drop", "lru_move", "pause_ms", "peak_rss_kb")
GCS = ("perceus", "incremental", "epoch", "rc")


def load(path: Path) -> dict[tuple[str, str], list[float]]:
    d: dict[tuple[str, str], list[float]] = collections.defaultdict(list)
    for line in path.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("N=") or s.startswith("##"):
            continue
        parts = s.split()
        if len(parts) != 3:
            continue
        g, op, v = parts
        try:
            d[(g, op)].append(float(v))
        except ValueError:
            continue
    return d


def med(xs: list[float]) -> float | None:
    return statistics.median(xs) if xs else None


def fmt(x: float | None) -> str:
    if x is None:
        return "—"
    return f"{x:.2f}"


def delta(c: float | None, z: float | None) -> str:
    if c is None or z is None or c == 0:
        return "—"
    pct = (z - c) * 100.0 / c
    tag = " SLOWER" if pct > 2 else ""
    return f"{pct:+.1f}%{tag}"


def main() -> int:
    ap = argparse.ArgumentParser(description="Compare C vs Zig ops-raw logs")
    ap.add_argument("c_raw")
    ap.add_argument("zig_raw")
    ap.add_argument("--label", default="unspecified host (set --label 'local Mac' only on a Mac)")
    args = ap.parse_args()
    c_path = Path(args.c_raw)
    z_path = Path(args.zig_raw)
    c = load(c_path)
    z = load(z_path)
    print(f"# C vs Zig ops comparison")
    print()
    print(f"- host_label: {args.label}")
    print(f"- c_raw: {c_path}")
    print(f"- zig_raw: {z_path}")
    print(f"- method: median of samples present in each raw file")
    print()
    print("| collector | op | C | Zig | Δ% |")
    print("|---|---|---:|---:|---:|")
    slower = False
    for g in GCS:
        for op in OPS:
            cv, zv = med(c[(g, op)]), med(z[(g, op)])
            if cv is None and zv is None:
                continue
            d = delta(cv, zv)
            if "SLOWER" in d and op != "peak_rss_kb":
                slower = True
            print(f"| {g} | {op} | {fmt(cv)} | {fmt(zv)} | {d} |")
    print()
    print("raw samples (C):")
    for g in GCS:
        for op in OPS:
            xs = c[(g, op)]
            if xs:
                print(f"  {g} {op}: {xs} med={statistics.median(xs):.2f}")
    print("raw samples (Zig):")
    for g in GCS:
        for op in OPS:
            xs = z[(g, op)]
            if xs:
                print(f"  {g} {op}: {xs} med={statistics.median(xs):.2f}")
    print()
    if slower:
        print("verdict: NOT READY (Zig is meaningfully slower in at least one category).")
    else:
        print("verdict: no >2% ns/op regression in the rows present. Still not a readiness claim if parity is incomplete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
