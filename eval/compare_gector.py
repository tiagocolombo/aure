#!/usr/bin/env python3
"""Benchmark GECToR (token-edit tagging) on eval/golden/*.jsonl.

usage: eval/.venv/bin/python eval/compare_gector.py MODEL_ID VERB_VOCAB_TXT
"""
import json, pathlib, sys, time
import psutil, torch
from transformers import AutoTokenizer
from gector import GECToR, predict, load_verb_dict

ROOT = pathlib.Path(__file__).resolve().parent.parent
torch.set_num_threads(6)
model_id, verb_file = sys.argv[1], sys.argv[2]

def cases():
    out = []
    for f in sorted((ROOT / "eval/golden").glob("*.jsonl")):
        out += [json.loads(l) for l in f.read_text().splitlines() if l.strip()]
    return out

def norm(s):
    s = s.replace("\u2019", "'").strip().rstrip(".").replace(" .", ".").replace(" ,", ",").replace(" ?", "?")
    return s[:1].lower() + s[1:]

proc = psutil.Process(); base = proc.memory_info().rss
model = GECToR.from_pretrained(model_id).eval()
tok = AutoTokenizer.from_pretrained(model_id)
encode, decode = load_verb_dict(verb_file)
mem = (proc.memory_info().rss - base) / 1e9

def fix(text):
    # GECToR works on whitespace-tokenized text; detokenize simple punctuation afterwards.
    import re
    spaced = re.sub(r"([.,!?;:])", r" \1", text)
    out = predict(model, tok, [spaced], encode, decode, keep_confidence=0.0, min_error_prob=0.0,
                  n_iteration=5, batch_size=1)[0]
    return re.sub(r" ([.,!?;:])", r"\1", out)

fix("warm up this model please")
ok = err = clean = kept = 0
lat = []
for c in cases():
    t = time.time(); out = fix(c["text"]); lat.append(time.time() - t)
    exp = c.get("expect")
    if exp is None:
        clean += 1; good = norm(out) == norm(c["text"]); kept += good
    else:
        err += 1; good = norm(out) in {norm(e) for e in exp}; ok += good
    if not good:
        print(f"   ✘ {c['text']}  →  {out}", flush=True)
lat.sort()
print(f"\n| {model_id} | {ok}/{err} ({100*ok//err}%) | {kept}/{clean} | {lat[len(lat)//2]:.2f}s | {lat[int(len(lat)*.95)]:.2f}s | {mem:.1f} GB |")
