#!/usr/bin/env python3
"""Build a harder JSONL eval set from the public BEA-2019 dev split
(W&I+LOCNESS learner essays, shipped in github.com/katerynkarpo/llm-en-gec).

Takes a fixed random sample: ~2/3 sentences with errors (expect = reference)
and ~1/3 correct sentences (expect = null, must stay unchanged).

usage: eval/make_bea_set.py SRC_DETOK REF_DETOK OUT.jsonl [N]
"""
import json, random, sys

src_path, ref_path, out_path = sys.argv[1:4]
n = int(sys.argv[4]) if len(sys.argv) > 4 else 150
src = open(src_path).read().splitlines()
ref = open(ref_path).read().splitlines()
assert len(src) == len(ref)
pairs = [(s.strip(), r.strip()) for s, r in zip(src, ref) if 6 <= len(s.split()) <= 40]
rng = random.Random(7)
errs = [p for p in pairs if p[0] != p[1]]
clean = [p for p in pairs if p[0] == p[1]]
rng.shuffle(errs)
rng.shuffle(clean)
sample = errs[: n * 2 // 3] + clean[: n - n * 2 // 3]
rng.shuffle(sample)
with open(out_path, "w") as f:
    for s, r in sample:
        f.write(json.dumps({"text": s, "tone": "formal", "expect": None if s == r else [r]}) + "\n")
print(f"wrote {len(sample)} cases ({sum(1 for s, r in sample if s != r)} with errors) to {out_path}")
