#!/usr/bin/env python3
"""Compare output formats on a running llama-server: JSON schema vs plain corrected text.
Usage: eval/probe_format.py PORT"""
import json, sys, urllib.request, pathlib

port = sys.argv[1]
cases = []
for f in sorted(pathlib.Path("eval/golden").glob("*.jsonl")):
    cases += [json.loads(l) for l in f.read_text().splitlines() if l.strip()]

SYS = ("You are a meticulous English proofreader. Fix every spelling, grammar and punctuation error, "
       "including commonly confused words (your/you're, its/it's, their/there/they're, then/than). "
       "Keep the writer's wording, tone, casing style and emoji; change only what is wrong. "
       "Reply with the corrected text only, nothing else. If it is already correct, repeat it exactly.")
SHOTS = [
    ("your right, its too late to change it now", "you're right, it's too late to change it now"),
    ("sounds good 👍 see you at 3", "sounds good 👍 see you at 3"),
    ("We received less applications then last year.", "We received fewer applications than last year."),
    ("Thank you for your help with the proposal.", "Thank you for your help with the proposal."),
]

def ask(text):
    msgs = [{"role": "system", "content": SYS}]
    for u, a in SHOTS:
        msgs += [{"role": "user", "content": u + "\n/no_think"}, {"role": "assistant", "content": a}]
    msgs.append({"role": "user", "content": text + "\n/no_think"})
    body = {"messages": msgs, "temperature": 0.1, "max_tokens": 300,
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req, timeout=120))["choices"][0]["message"]["content"]
    if "</think>" in out:
        out = out.split("</think>", 1)[1]
    return out.strip()

norm = lambda s: s.replace("\u2019", "'").strip()
ok = err = clean = cleanok = 0
for c in cases:
    out = ask(c["text"])
    exp = c.get("expect")
    if exp is None:
        clean += 1; good = norm(out) == norm(c["text"]); cleanok += good
    else:
        err += 1; good = norm(out) in map(norm, exp); ok += good
    if not good:
        print(f"✘ {c['text']}\n   → {out}")
print(f"\nplain-text format: exact fix {ok}/{err}, clean kept {cleanok}/{clean}")
