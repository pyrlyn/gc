#!/usr/bin/env python3
"""In-memory tests for the mixed-N ops-raw parser. No CLI file paths."""
from __future__ import annotations

import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare as c  # noqa: E402


def assert_eq(got, want, msg: str) -> None:
    if got != want:
        raise SystemExit(f"FAIL {msg}: got {got!r} want {want!r}")


def test_unlabeled_defaults_to_4m() -> None:
    d = c.parse_ops_raw("epoch field_store 5.61\nepoch pause_ms 266.1\n")
    assert_eq(set(d), {(4_000_000, "epoch", "field_store"), (4_000_000, "epoch", "pause_ms")}, "unlabeled N")
    assert_eq(d[(4_000_000, "epoch", "field_store")], [5.61], "unlabeled sample")


def test_section_header_binds_following_lines() -> None:
    text = """
## N=100000
epoch field_store 8.00
epoch pause_ms 27.4
## N=4000000
epoch field_store 5.61
epoch pause_ms 266.1
"""
    d = c.parse_ops_raw(text)
    assert_eq(d[(100_000, "epoch", "field_store")], [8.00], "100k field")
    assert_eq(d[(4_000_000, "epoch", "pause_ms")], [266.1], "4M pause")
    assert (4_000_000, "epoch", "field_store") in d
    assert (100_000, "epoch", "pause_ms") in d


def test_inline_n_and_round_prefix() -> None:
    text = "N=1000000 round=2 incremental alloc_drop 3.40\n"
    d = c.parse_ops_raw(text)
    assert_eq(d[(1_000_000, "incremental", "alloc_drop")], [3.40], "inline N")


def test_mixed_n_does_not_pollute_4m_pause() -> None:
    """The reported false +104%: C 100k+1M+4M pause mixed vs Zig 4M-only."""
    c_text = """
## N=100000
epoch pause_ms 26.0
## N=1000000
epoch pause_ms 130.44
## N=4000000
epoch pause_ms 522.0
epoch field_store 4.46
"""
    z_text = """
# N unlabeled = official 4M interleaved
epoch pause_ms 266.1
epoch field_store 5.61
"""
    c_d, z_d = c.parse_ops_raw(c_text), c.parse_ops_raw(z_text)
    # Old unlabeled aggregation: median(26.0, 130.44, 522.0)=130.44 vs Zig 266.1 → +104.0%.
    mixed_old = statistics.median([26.0, 130.44, 522.0])
    false_pct = (266.1 - mixed_old) * 100.0 / mixed_old
    if abs(false_pct - 104.0) > 0.05:
        raise SystemExit(f"FAIL toy numbers no longer illustrate +104% (got {false_pct:.1f}%)")
    c4 = statistics.median(c_d[(4_000_000, "epoch", "pause_ms")])
    assert_eq(c4, 522.0, "C 4M pause isolated")
    out = c.render(
        c_d,
        z_d,
        label="test",
        pair="mac-local",
        c_name="mem-c",
        z_name="mem-z",
    )
    if "+104%" in out or "104.0%" in out:
        raise SystemExit("FAIL mixed-N still produced a +104% pause row")
    if "-49.0%" not in out:
        raise SystemExit(f"FAIL expected same-N 4M pause Δ (266.1-522)/522 = -49.0% in:\n{out}")
    if "522.00" not in out or "266.10" not in out:
        raise SystemExit(f"FAIL expected same-N 4M pause 522 vs 266 in:\n{out}")
    if "missing Zig" not in out:
        raise SystemExit("FAIL expected explicit missing Zig for C-only 100k/1M pause")
    if "N=100000 epoch pause_ms: Zig only" in out or "N=100000 epoch pause_ms: C only" not in out:
        raise SystemExit("FAIL expected C-only 100k pause listed as missing counterpart")
    # 4M field_store must compare 4.46 vs 5.61, not a mix
    if "4.46" not in out or "5.61" not in out:
        raise SystemExit("FAIL expected 4M field_store 4.46 vs 5.61")


def test_concatenated_4m_then_size_sweep() -> None:
    """Official 4M unlabeled block followed by a size sweep — the Mac paired layout."""
    text = """
# start
# round 1
epoch pause_ms 522.0
epoch field_store 4.46
## N=100000
N=100000 round=1 epoch pause_ms 26.0
N=100000 round=1 epoch field_store 8.00
## N=4000000
N=4000000 round=1 epoch pause_ms 521.0
"""
    d = c.parse_ops_raw(text)
    assert_eq(d[(4_000_000, "epoch", "pause_ms")], [522.0, 521.0], "4M pauses stay 4M")
    assert_eq(d[(100_000, "epoch", "pause_ms")], [26.0], "100k pause isolated")
    assert_eq(len(d[(4_000_000, "epoch", "field_store")]), 1, "4M field only")


def test_skips_hash_and_unknown() -> None:
    d = c.parse_ops_raw("# start\n# round 1\nfoo bar 1\nperceus rc_pair x\n")
    assert_eq(d, {}, "noise")


def main() -> int:
    test_unlabeled_defaults_to_4m()
    test_section_header_binds_following_lines()
    test_inline_n_and_round_prefix()
    test_mixed_n_does_not_pollute_4m_pause()
    test_concatenated_4m_then_size_sweep()
    test_skips_hash_and_unknown()
    print("test_compare.py: 6 PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
