#!/usr/bin/env python3
"""Compare candidate models on eval/golden/*.jsonl.

Starts llama-server per model, sends each case in the model's native style,
and scores corrected text (exact match with an acceptable answer; clean text
must stay unchanged). Ignores a trailing period and first-letter case, since
those are style, not errors.

usage: eval/compare_models.py MODEL.gguf[:style] ...
  style: chat (instruction + few-shot, default) | plain (raw text in, corrected out: GRMR)
"""
import json, os, pathlib, subprocess, sys, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = str(ROOT / "build/llama/llama-server")
PORT = 18090

SYS = ("You are a meticulous English proofreader. Fix every spelling, grammar and punctuation error, "
       "including commonly confused words (your/you're, its/it's, their/there/they're, then/than, "
       "should of/should have) and subject-verb agreement. Keep the writer's wording, tone, "
       "capitalization style, emoji, @mentions and URLs; change only what is wrong. "
       "Reply with the corrected text only. If it is already correct, repeat it exactly.")
SHOTS = [
    ("your right, its too late to change it now", "you're right, it's too late to change it now"),
    ("sounds good 👍 see you at 3", "sounds good 👍 see you at 3"),
    ("We received less applications then last year.", "We received fewer applications than last year."),
    ("Thank you for your help with the proposal.", "Thank you for your help with the proposal."),
]

def cases():
    out = []
    for f in sorted((ROOT / "eval/golden").glob("*.jsonl")):
        out += [json.loads(l) for l in f.read_text().splitlines() if l.strip()]
    return out

def post(body):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req, timeout=300))["choices"][0]["message"]["content"] or ""
    if "</think>" in out:
        out = out.split("</think>", 1)[1]
    return out.strip()

def ask(text, style):
    if style == "plain":
        return post({"messages": [{"role": "user", "content": text}], "temperature": 0.1, "top_p": 0.95,
                     "min_p": 0.01, "max_tokens": 300})
    msgs = [{"role": "system", "content": SYS}]
    for u, a in SHOTS:
        msgs += [{"role": "user", "content": u}, {"role": "assistant", "content": a}]
    msgs.append({"role": "user", "content": text})
    return post({"messages": msgs, "temperature": 0.1, "max_tokens": 300,
                 "chat_template_kwargs": {"enable_thinking": False}})

def norm(s):
    s = s.replace("\u2019", "'").strip().rstrip(".")
    return s[:1].lower() + s[1:]

def run(model, style):
    log = open(f"/tmp/cmp-{pathlib.Path(model).stem}.log", "w")
    p = subprocess.Popen([SERVER, "-m", model, "--host", "127.0.0.1", "--port", str(PORT), "-c", "4096",
                          "-ngl", "0", "-t", str(max(1, (os.cpu_count() or 4) // 2)), "--jinja", "--no-webui", "-np", "1"],
                         stdout=log, stderr=log)
    try:
        for _ in range(240):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2); break
            except Exception:
                time.sleep(1)
        ask("warm up this model please", style)
        ok = err = clean = kept = 0
        lat, misses = [], []
        for c in cases():
            t = time.time(); out = ask(c["text"], style); lat.append(time.time() - t)
            exp = c.get("expect")
            if exp is None:
                clean += 1; good = norm(out) == norm(c["text"]); kept += good
            else:
                err += 1; good = norm(out) in {norm(e) for e in exp}; ok += good
            if not good:
                misses.append(f"   ✘ {c['text']}  →  {out}")
        lat.sort()
        return ok, err, kept, clean, lat[len(lat) // 2], lat[int(len(lat) * .95)], misses
    finally:
        p.terminate(); p.wait()

if __name__ == "__main__":
    rows = []
    for arg in sys.argv[1:]:
        model, _, style = arg.partition(":")
        style = style or "chat"
        name = pathlib.Path(model).stem
        print(f"== {name} ({style})", flush=True)
        ok, err, kept, clean, p50, p95, misses = run(model, style)
        print("\n".join(misses), flush=True)
        rows.append((name, ok, err, kept, clean, p50, p95))
    print("\n| model | errors fixed | clean kept | p50 | p95 |\n|---|---|---|---|---|")
    for name, ok, err, kept, clean, p50, p95 in rows:
        print(f"| {name} | {ok}/{err} ({100*ok//err}%) | {kept}/{clean} | {p50:.1f}s | {p95:.1f}s |")
