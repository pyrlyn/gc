#!/usr/bin/env python3
"""Markdown table from result files ("key value" per line, '#' comments): one column per file, best
(lowest) value per row in bold. Usage: table.py [--metric NAME] label=file [label=file ...]"""
import sys
args = sys.argv[1:]
metric = "case, ms"
if args and args[0] == "--metric": metric, args = args[1], args[2:]
cols, data, keys = [], [], []
for a in args:
    label, path = a.split("=", 1)
    d = {}
    for line in open(path):
        if line.startswith("#") or not line.strip(): continue
        k, v = line.split()[:2]
        d[k] = float(v)
        if k not in keys: keys.append(k)
    cols.append(label); data.append(d)
print("| " + metric + " | " + " | ".join(cols) + " |")
print("|---" * (len(cols) + 1) + "|")
for k in keys:
    vals = [d.get(k) for d in data]
    present = [v for v in vals if v is not None]
    best = min(present) if present else None
    cells = []
    for v in vals:
        if v is None: cells.append("—"); continue
        s = f"{v:g}"
        cells.append(f"**{s}**" if len(present) > 1 and v == best else s)
    print(f"| {k} | " + " | ".join(cells) + " |")
