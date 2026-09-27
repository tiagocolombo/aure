#!/usr/bin/env python3
"""Per-edit precision/recall/F0.5 for aure-eval verbose output on a JSONL set.

Edits are word-level diffs (difflib opcodes) from source to output, compared
with edits from source to the reference. An output edit counts as correct if
the reference has the identical edit (same source span, same replacement).
This approximates the ERRANT/M2 metric used in GEC papers.

usage: eval/edit_f05.py SET.jsonl RUN_OUTPUT.txt [threshold]
  RUN_OUTPUT must come from `aure-eval --verbose` (prints every case).
"""
import difflib, json, re, sys

cases = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
threshold = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
lines = open(sys.argv[2]).read().splitlines()

outputs = {}
i = 0
while i < len(lines):
    m = re.match(r"^[✔✘] \[[^\]]+\] (.*)$", lines[i])
    if m and i + 1 < len(lines) and lines[i + 1].startswith("    → "):
        src = m.group(1)
        out = re.sub(r" \[.*\]$", "", lines[i + 1][6:])
        found = []
        j = i + 2
        while j < len(lines) and re.match(r"^\s+[0-9.]+\s+\"", lines[j]):
            em = re.match(r'^\s+([0-9.]+)\s+"(.*)" → "(.*)"$', lines[j])
            if em:
                found.append((float(em.group(1)), em.group(2), em.group(3)))
            j += 1
        outputs[src] = (out, found)
        i = j
    else:
        i += 1


def tok(s):
    return re.findall(r"\w+(?:'\w+)?|[^\w\s]", s)


def edits(a, b):
    ta, tb = tok(a), tok(b)
    return {(i1, i2, " ".join(tb[j1:j2])) for op, i1, i2, j1, j2 in
            difflib.SequenceMatcher(None, ta, tb, autojunk=False).get_opcodes() if op != "equal"}


tp = fp = fn = 0
missing = 0
for c in cases:
    src = c["text"]
    ref = (c.get("expect") or [src])[0]
    if src not in outputs:
        missing += 1
        continue
    out, raw = outputs[src]
    if threshold > 0:
        # Rebuild output keeping only edits above threshold (low-confidence ones reverted).
        for conf, o, r in raw:
            if conf < threshold and r and r in out:
                out = out.replace(r, o, 1)
    hyp, gold = edits(src, out), edits(src, ref)
    tp += len(hyp & gold)
    fp += len(hyp - gold)
    fn += len(gold - hyp)

p = tp / (tp + fp) if tp + fp else 1.0
r = tp / (tp + fn) if tp + fn else 1.0
f = (1.25 * p * r / (0.25 * p + r)) if p + r else 0.0
print(f"cases={len(cases)-missing} (missing {missing})  P={p:.3f} R={r:.3f} F0.5={f:.3f}  (tp={tp} fp={fp} fn={fn})")
