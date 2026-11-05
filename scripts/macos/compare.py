#!/usr/bin/env python3
"""Compare C vs Zig ops-raw logs from fixed artifact locations.

No filesystem path is taken from the command line (Sonar AaGuAJygRUAgjXuXSY5_).

Parses N sections. Unlabeled `collector op value` lines default to N=4000000
(the official interleaved protocol). Lines may also carry `N=…` inline
(`N=100000 round=1 perceus rc_pair 1.34`) or follow `## N=100000`.

Compares only matching (N, collector, op) samples. Missing side is printed
explicitly — never mixes 100k/1M pause_ms into a 4M median.

Usage (from repo root):
  python3 scripts/macos/compare.py --pair mac-local --label "local Mac"
  python3 scripts/macos/test_compare.py
"""
from __future__ import annotations

import argparse
import collections
import re
import statistics
import sys
from pathlib import Path


OPS = ("rc_pair", "field_store", "alloc_drop", "lru_move", "pause_ms", "peak_rss_kb")
GCS = ("perceus", "incremental", "epoch", "rc")
DEFAULT_N = 4_000_000
PRIMARY_N = 4_000_000

_N_TOKEN = re.compile(r"^N=(\d+)$")
_N_HEADER = re.compile(r"^#+\s*N=(\d+)\s*$")


def parse_ops_raw(text: str) -> dict[tuple[int, str, str], list[float]]:
    """Parse ops-raw text into {(N, collector, op): [samples]}."""
    d: dict[tuple[int, str, str], list[float]] = collections.defaultdict(list)
    current_n = DEFAULT_N
    for raw in text.splitlines():
        s = raw.strip()
        if not s:
            continue
        header = _N_HEADER.match(s)
        if header:
            current_n = int(header.group(1))
            continue
        if s.startswith("#"):
            continue
        n = current_n
        tokens: list[str] = []
        for tok in s.split():
            mt = _N_TOKEN.match(tok)
            if mt:
                n = int(mt.group(1))
                continue
            if tok.startswith("round="):
                continue
            tokens.append(tok)
        if len(tokens) < 3:
            continue
        g, op, vs = tokens[-3], tokens[-2], tokens[-1]
        if g not in GCS or op not in OPS:
            continue
        try:
            val = float(vs)
        except ValueError:
            continue
        d[(n, g, op)].append(val)
    return dict(d)


def ns_present(d: dict[tuple[int, str, str], list[float]]) -> list[int]:
    return sorted({n for n, _, _ in d})


def med(xs: list[float]) -> float | None:
    return statistics.median(xs) if xs else None


def fmt(x: float | None) -> str:
    if x is None:
        return "—"
    return f"{x:.2f}"


def delta(c: float | None, z: float | None) -> str:
    if c is None and z is None:
        return "—"
    if c is None:
        return "missing C"
    if z is None:
        return "missing Zig"
    if c == 0:
        return "—" if z == 0 else "n/a"
    pct = (z - c) * 100.0 / c
    tag = " SLOWER" if pct > 2 else ""
    return f"{pct:+.1f}%{tag}"


def read_mac_local_c() -> str:
    return Path("artifacts/macos-local/c/logs/ops-raw.txt").read_text()


def read_mac_local_zig() -> str:
    return Path("artifacts/macos-local/zig/logs/ops-raw.txt").read_text()


def read_vm_c() -> str:
    return Path("artifacts/c-baseline/logs/ops-raw.txt").read_text()


def read_vm_zig() -> str:
    return Path("artifacts/zig-bench/logs/ops-raw.txt").read_text()


def render(c: dict, z: dict, *, label: str, pair: str, c_name: str, z_name: str) -> str:
    lines: list[str] = [
        "# C vs Zig ops comparison",
        "",
        f"- host_label: {label}",
        f"- pair: {pair}",
        f"- c_raw: {c_name}",
        f"- zig_raw: {z_name}",
        "- method: median of samples with the same N, collector, and op",
        f"- default_unlabeled_N: {DEFAULT_N}",
        "",
    ]
    all_n = sorted(set(ns_present(c)) | set(ns_present(z)))
    if not all_n:
        lines.append("no samples")
        return "\n".join(lines) + "\n"
    slower = False
    for n in all_n:
        lines.append(f"## N={n}")
        lines.append("")
        lines.append("| collector | op | C | Zig | Δ% |")
        lines.append("|---|---|---:|---:|---:|")
        for g in GCS:
            for op in OPS:
                cv, zv = med(c.get((n, g, op), [])), med(z.get((n, g, op), []))
                if cv is None and zv is None:
                    continue
                d = delta(cv, zv)
                if "SLOWER" in d:
                    slower = True
                lines.append(f"| {g} | {op} | {fmt(cv)} | {fmt(zv)} | {d} |")
        lines.append("")
        if n == PRIMARY_N:
            lines.append("primary protocol N=4000000 (interleaved rounds).")
            lines.append("")
    lines.append("raw samples (C):")
    for n, g, op in sorted(c):
        xs = c[(n, g, op)]
        if not xs:
            continue
        lines.append(f"  N={n} {g} {op}: {xs} med={statistics.median(xs):.2f}")
    lines.append("raw samples (Zig):")
    for n, g, op in sorted(z):
        xs = z[(n, g, op)]
        if not xs:
            continue
        lines.append(f"  N={n} {g} {op}: {xs} med={statistics.median(xs):.2f}")
    missing = []
    for n in all_n:
        for g in GCS:
            for op in ("rc_pair", "field_store", "alloc_drop", "lru_move", "pause_ms"):
                ch, zh = (n, g, op) in c, (n, g, op) in z
                if ch != zh:
                    missing.append(f"  N={n} {g} {op}: {'C only' if ch else 'Zig only'}")
    lines.append("")
    if missing:
        lines.append("missing counterpart (not compared as a mixed-N median):")
        lines.extend(missing)
        lines.append("")
    if slower:
        lines.append("verdict: NOT READY (Zig is meaningfully slower in at least one same-N category).")
    else:
        lines.append(
            "verdict: no >2% same-N ns/op regression in the rows present. "
            "Still not a readiness claim if parity is incomplete."
        )
    return "\n".join(lines) + "\n"


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
        c_text, z_text = read_mac_local_c(), read_mac_local_zig()
        c_name = "artifacts/macos-local/c/logs/ops-raw.txt"
        z_name = "artifacts/macos-local/zig/logs/ops-raw.txt"
        label = args.label or "local Mac (artifact pair)"
    else:
        c_text, z_text = read_vm_c(), read_vm_zig()
        c_name = "artifacts/c-baseline/logs/ops-raw.txt"
        z_name = "artifacts/zig-bench/logs/ops-raw.txt"
        label = args.label or "Linux VM guide only (not local Mac)"
    sys.stdout.write(
        render(
            parse_ops_raw(c_text),
            parse_ops_raw(z_text),
            label=label,
            pair=args.pair,
            c_name=c_name,
            z_name=z_name,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
