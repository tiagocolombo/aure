#!/usr/bin/env python3
"""Scores aure-eval --out results on eval/long/emails.jsonl.

Per case:
  - planted errors fixed (reference edits present in the output)
  - extra changes (output edits not in the reference), listed so a human can
    judge whether they are real improvements or false alarms
  - layout kept: same line breaks, blank lines, bullet/number prefixes, sign-off
  - whether the validator rejected the whole answer

usage: eval/score_long.py eval/long/emails.jsonl RESULTS.jsonl [--show]
"""
import difflib, json, re, sys

cases = {c["text"]: c for c in map(json.loads, open(sys.argv[1])) if c}
results = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
show = "--show" in sys.argv


def tok(s):
    return re.findall(r"\w+(?:'\w+)?|[^\w\s]|\n", s)


def edits(a, b):
    ta, tb = tok(a), tok(b)
    return {(i1, i2, " ".join(ta[i1:i2]), " ".join(tb[j1:j2])) for op, i1, i2, j1, j2 in
            difflib.SequenceMatcher(None, ta, tb, autojunk=False).get_opcodes() if op != "equal"}


def layout(s):
    # Line structure: blank lines and list prefixes, not the words.
    return [("" if not l.strip() else re.match(r"^\s*(?:[-*•]|\d+\.)?\s?", l).group(0).strip() or "text")
            for l in s.split("\n")]


tot = dict(planted=0, fixed=0, extra=0, clean_cases=0, clean_kept=0, layout_ok=0, rejected=0)
lat = []
for r in results:
    c = cases[r["text"]]
    src, out = r["text"], r["output"]
    ref = (c.get("expect") or [src])[0]
    gold, hyp = edits(src, ref), edits(src, out)
    fixed = len(gold & hyp)
    extra = sorted(hyp - gold)
    lay = layout(src) == layout(out)
    tot["planted"] += len(gold)
    tot["fixed"] += fixed
    tot["extra"] += len(extra)
    tot["layout_ok"] += lay
    tot["rejected"] += bool(r.get("error"))
    if not gold:
        tot["clean_cases"] += 1
        tot["clean_kept"] += out == src
    lat.append(r["latency_ms"])
    missed = sorted(gold - hyp)
    print(f"{'✔' if not missed and not extra and lay else '✘'} {c['note']} ({len(src)} chars, {r['latency_ms']} ms)"
          f": fixed {fixed}/{len(gold)}, extra {len(extra)}{'' if lay else ', LAYOUT CHANGED'}"
          f"{' [' + r['error'].strip() + ']' if r.get('error') else ''}")
    if show or missed or extra:
        for e in missed:
            print(f"    missed: {e[2]!r} → {e[3]!r}")
        for e in extra:
            conf = next((i["confidence"] for i in r["issues"] if e[2].replace(" ", "") in i["original"].replace(" ", "")
                         and e[3].replace(" ", "") in i["replacement"].replace(" ", "")), None)
            print(f"    extra:  {e[2]!r} → {e[3]!r}" + (f"  (conf {conf:.2f})" if conf is not None else ""))
    if not lay:
        for d in difflib.unified_diff(src.split("\n"), out.split("\n"), lineterm="", n=0):
            print("      " + d)

n = len(results)
lat.sort()
print(f"\n{n} texts: planted errors fixed {tot['fixed']}/{tot['planted']} "
      f"({100 * tot['fixed'] / max(1, tot['planted']):.0f}%), extra changes {tot['extra']}, "
      f"clean texts untouched {tot['clean_kept']}/{tot['clean_cases']}, layout kept {tot['layout_ok']}/{n}, "
      f"rejected {tot['rejected']}; latency p50 {lat[n // 2]} ms, max {lat[-1]} ms")
