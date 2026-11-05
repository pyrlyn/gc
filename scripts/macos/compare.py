#!/usr/bin/env python3
"""Compare C vs Zig ops-raw logs from fixed artifact locations.

No filesystem path is taken from the command line (Sonar AaGuAJygRUAgjXuXSY5_).
Copy Mac C logs into the artifact slot first if they live elsewhere:

  mkdir -p artifacts/macos-local/c/logs
  cp ~/Grok/gc-local-bench/c-logs/ops-raw.txt artifacts/macos-local/c/logs/

Usage (from repo root):
  python3 scripts/macos/compare.py --pair mac-local --label "local Mac"
"""
from __future__ import annotations

import argparse
import collections
import statistics
import sys
from pathlib import Path


OPS = ("rc_pair", "field_store", "alloc_drop", "lru_move", "pause_ms", "peak_rss_kb")
GCS = ("perceus", "incremental", "epoch", "rc")


def load_ops_raw(text: str) -> dict[tuple[str, str], list[float]]:
    d: dict[tuple[str, str], list[float]] = collections.defaultdict(list)
    for line in text.splitlines():
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


def read_mac_local_c() -> str:
    return Path("artifacts/macos-local/c/logs/ops-raw.txt").read_text()


def read_mac_local_zig() -> str:
    return Path("artifacts/macos-local/zig/logs/ops-raw.txt").read_text()


def read_vm_c() -> str:
    return Path("artifacts/c-baseline/logs/ops-raw.txt").read_text()


def read_vm_zig() -> str:
    return Path("artifacts/zig-bench/logs/ops-raw.txt").read_text()


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
    ap = argparse.ArgumentParser(description="Compare fixed C vs Zig ops-raw artifact pairs")
    ap.add_argument(
        "--pair",
        required=True,
        choices=("mac-local", "vm-guide"),
        help="mac-local: artifacts/macos-local/{c,zig}/logs/ops-raw.txt; "
        "vm-guide: frozen Linux VM artifacts (not a Mac result)",
    )
    ap.add_argument("--label", default="")
    args = ap.parse_args()
    if args.pair == "mac-local":
        c_text = read_mac_local_c()
        z_text = read_mac_local_zig()
        c_name = "artifacts/macos-local/c/logs/ops-raw.txt"
        z_name = "artifacts/macos-local/zig/logs/ops-raw.txt"
        label = args.label or "local Mac (artifact pair)"
    else:
        c_text = read_vm_c()
        z_text = read_vm_zig()
        c_name = "artifacts/c-baseline/logs/ops-raw.txt"
        z_name = "artifacts/zig-bench/logs/ops-raw.txt"
        label = args.label or "Linux VM guide only (not local Mac)"
    c = load_ops_raw(c_text)
    z = load_ops_raw(z_text)
    print("# C vs Zig ops comparison")
    print()
    print(f"- host_label: {label}")
    print(f"- pair: {args.pair}")
    print(f"- c_raw: {c_name}")
    print(f"- zig_raw: {z_name}")
    print("- method: median of samples present in each raw file")
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
