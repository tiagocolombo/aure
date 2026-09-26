#!/usr/bin/env python3
"""Benchmark seq2seq grammar models (T5 family) on eval/golden/*.jsonl with the
same scoring as compare_models.py. Reports accuracy, latency and peak memory.

usage: eval/.venv/bin/python eval/compare_seq2seq.py MODEL_ID[:prefix] ...
"""
import json, pathlib, sys, time
import psutil, torch
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

ROOT = pathlib.Path(__file__).resolve().parent.parent
torch.set_num_threads(6)

def cases():
    out = []
    for f in sorted((ROOT / "eval/golden").glob("*.jsonl")):
        out += [json.loads(l) for l in f.read_text().splitlines() if l.strip()]
    return out

def norm(s):
    s = s.replace("\u2019", "'").strip().rstrip(".")
    return s[:1].lower() + s[1:]

rows = []
for arg in sys.argv[1:]:
    model_id, _, prefix = arg.partition(":")
    print(f"== {model_id} (prefix={prefix!r})", flush=True)
    proc = psutil.Process()
    base = proc.memory_info().rss
    tok = AutoTokenizer.from_pretrained(model_id)
    model = AutoModelForSeq2SeqLM.from_pretrained(model_id, torch_dtype=torch.float32).eval()
    mem = (proc.memory_info().rss - base) / 1e9

    def fix(text):
        ids = tok(prefix + text, return_tensors="pt")
        with torch.no_grad():
            out = model.generate(**ids, max_new_tokens=128, num_beams=2)
        return tok.decode(out[0], skip_special_tokens=True).strip()

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
    rows.append((model_id, ok, err, kept, clean, lat[len(lat) // 2], lat[int(len(lat) * .95)], mem))
    del model

print("\n| model | errors fixed | clean kept | p50 | p95 | RAM |\n|---|---|---|---|---|---|")
for m, ok, err, kept, clean, p50, p95, mem in rows:
    print(f"| {m} | {ok}/{err} ({100*ok//err}%) | {kept}/{clean} | {p50:.2f}s | {p95:.2f}s | {mem:.1f} GB |")
