#!/usr/bin/env python3
"""Summarizes mutation/run.sh results: caught (killed + timeout) vs survived per file, and cross-references
every survivor with coverage/uncovered.txt (from `zig build coverage`): a survivor on a never-executed line
is a coverage gap; one on an executed line is an assertion gap.
usage: report.py WORK_DIR [COVERAGE_UNCOVERED_TXT]"""
import json, os, sys, glob, collections
work = sys.argv[1]
unc_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "..", "coverage", "uncovered.txt")
uncovered = set(open(unc_path).read().split()) if os.path.exists(unc_path) else None
rows = []
for f in glob.glob(os.path.join(work, "*", "results.jsonl")):
    rows += [json.loads(l) for l in open(f)]
per = collections.defaultdict(collections.Counter)
for r in rows: per[r["file"]][r["status"]] += 1
print(f"{'file':40} {'mutants':>7} {'killed':>6} {'timeout':>7} {'survived':>8} {'score':>6}")
tot = collections.Counter()
for f, c in sorted(per.items()):
    n = sum(c.values()); caught = c["killed"] + c["timeout"]; tot.update(c)
    print(f"{f:40} {n:7} {c['killed']:6} {c['timeout']:7} {c['survived']:8} {100*caught/n:5.1f}%")
n = sum(tot.values())
if n: print(f"{'TOTAL':40} {n:7} {tot['killed']:6} {tot['timeout']:7} {tot['survived']:8} {100*(tot['killed']+tot['timeout'])/n:5.1f}%")
print("\nsurvivors:")
for r in sorted((r for r in rows if r["status"] == "survived"), key=lambda r: (r["file"], r["line"])):
    cov = "" if uncovered is None else (" [UNCOVERED line]" if f"{r['file']}:{r['line']}" in uncovered else " [covered]")
    print(f"  {r['file']}:{r['line']} [{r['op']}]{cov}\n    - {r['old']}\n    + {r['new']}")
