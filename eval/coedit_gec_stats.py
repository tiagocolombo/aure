#!/usr/bin/env python3
"""Stats on the GEC part of CoEdIT: unchanged rate, edit size, and examples
that involve commonly confused words. usage: eval/coedit_gec_stats.py train.jsonl"""
import json, re, sys, difflib

conf = re.compile(r"\b(your|you're|its|it's|their|there|they're|then|than|whose|who's|lose|loose|affect|effect)\b", re.I)
n = same = 0
ratios = []
hits = []
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r["task"] != "gec":
        continue
    src = r["src"].split(":", 1)[1].strip()
    tgt = r["tgt"].strip()
    n += 1
    if src == tgt:
        same += 1
    a, b = src.split(), tgt.split()
    ratios.append(1 - difflib.SequenceMatcher(None, a, b).ratio())
    sw = {w.lower() for w in conf.findall(src)}
    tw = {w.lower() for w in conf.findall(tgt)}
    if sw != tw and len(hits) < 8 and len(src) < 140:
        hits.append((src, tgt))
ratios.sort()
print(f"gec examples: {n}; unchanged: {same} ({100*same/n:.1f}%)")
print(f"word-level change: median {ratios[n//2]:.2f}, p90 {ratios[int(n*.9)]:.2f}")
print("\nconfused-word examples:")
for s, t in hits:
    print(f"  SRC: {s}\n  TGT: {t}\n")
