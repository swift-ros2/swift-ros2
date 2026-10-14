#!/usr/bin/env python3
"""Compare two rcl-bench outputs row by row.

Usage: compare-rcl-bench.py <baseline.txt> <candidate.txt>
Prints one line per (mode, payload) with the throughput and p95 ratios, marking a row
REGRESSION when throughput drops or p95 latency grows by more than 10%. The numbers are
recorded in the pull request; a regression becomes a follow-up issue, not a stop. Exits 1
when any row regressed or is missing, so a caller can tell.
"""
import sys


def load(path):
    rows = {}
    for line in open(path):
        if "rcl_bench RESULT" not in line:
            continue
        kv = dict(item.split("=", 1) for item in line.split("RESULT ", 1)[1].split())
        rows[(kv["mode"], kv["payload"])] = kv
    return rows


def ratio(new, old, key):
    a, b = float(new.get(key, 0) or 0), float(old.get(key, 0) or 0)
    return a / b if a > 0 and b > 0 else None


base, cand = load(sys.argv[1]), load(sys.argv[2])
ok = True
for key in sorted(base):
    if key not in cand:
        print(f"{key}: missing from candidate REGRESSION")
        ok = False
        continue
    tput, p95 = ratio(cand[key], base[key], "msgs_per_s"), ratio(cand[key], base[key], "p95us")
    good = (tput is None or tput >= 0.9) and (p95 is None or p95 <= 1.1)
    ok &= good
    fmt = lambda r: "n/a" if r is None else f"x{r:.2f}"
    print(f"{key}: throughput {fmt(tput)}, p95 {fmt(p95)} {'OK' if good else 'REGRESSION'}")
sys.exit(0 if ok else 1)
