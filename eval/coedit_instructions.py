#!/usr/bin/env python3
"""Summarize the instruction phrasings in Grammarly's public CoEdIT dataset.
usage: eval/coedit_instructions.py train.jsonl"""
import collections, json, sys

by_task = collections.defaultdict(collections.Counter)
examples = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    src = r["src"]
    instr = src.split(":", 1)[0].strip() if ":" in src else src[:60]
    by_task[r["task"]][instr] += 1
    examples.setdefault(r["task"], (src[:220], r["tgt"][:220]))

for task, c in sorted(by_task.items(), key=lambda kv: -sum(kv[1].values())):
    print(f"\n## {task}  ({sum(c.values())} examples, {len(c)} phrasings)")
    for instr, n in c.most_common(12):
        print(f"  {n:6}  {instr}")
    s, t = examples[task]
    print(f"  e.g. SRC: {s}\n       TGT: {t}")
