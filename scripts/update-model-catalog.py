#!/usr/bin/env python3
"""Regenerate Packages/AureKit/Sources/AureModels/Resources/models.json.

Reads exact byte sizes and sha256 (LFS oid) from the Hugging Face tree API so
the app can verify downloads. Run: scripts/update-model-catalog.py
"""
import json
import pathlib
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Packages/AureKit/Sources/AureModels/Resources/models.json"

# Ordered best-first. Accuracy numbers come from docs/MODEL_EVAL.md.
MODELS = [
    {
        "id": "qwen3.5-4b",
        "name": "Qwen3.5 4B",
        "repo": "bartowski/Qwen_Qwen3.5-4B-GGUF",
        "file": "Qwen_Qwen3.5-4B-Q4_K_M.gguf",
        "family": "qwen3",
        "summary": "Most accurate: fixed 87% of English and 85% of Portuguese test errors. Best on Apple Silicon.",
        "minRAMGB": 8,
        "license": "Apache-2.0",
    },
    {
        "id": "qwen3-4b",
        "name": "Qwen3 4B",
        "repo": "Qwen/Qwen3-4B-GGUF",
        "file": "Qwen3-4B-Q4_K_M.gguf",
        "family": "qwen3",
        "summary": "Fixed 90% of English test errors but only 66% of Portuguese ones. Faster on Intel Macs.",
        "minRAMGB": 8,
        "license": "Apache-2.0",
    },
    {
        "id": "qwen3-1.7b",
        "name": "Qwen3 1.7B",
        "repo": "bartowski/Qwen_Qwen3-1.7B-GGUF",
        "file": "Qwen_Qwen3-1.7B-Q4_K_M.gguf",
        "family": "qwen3",
        "summary": "Faster and smaller: fixed 84% of test errors. Good for 8 GB Macs.",
        "minRAMGB": 4,
        "license": "Apache-2.0",
    },
    {
        "id": "qwen3-0.6b",
        "name": "Qwen3 0.6B",
        "repo": "bartowski/Qwen_Qwen3-0.6B-GGUF",
        "file": "Qwen_Qwen3-0.6B-Q4_K_M.gguf",
        "family": "qwen3",
        "summary": "Fastest, but basic: misses many errors (45%). Only for very old or low-memory Macs.",
        "minRAMGB": 4,
        "license": "Apache-2.0",
    },
]


def tree(repo):
    url = f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true"
    with urllib.request.urlopen(url, timeout=30) as r:
        return {e["path"]: e for e in json.load(r) if e.get("type") == "file"}


def main():
    out = []
    for m in MODELS:
        entry = tree(m["repo"])[m["file"]]
        m = dict(m)
        m["bytes"] = entry["size"]
        m["sha256"] = entry["lfs"]["oid"]
        m["url"] = f"https://huggingface.co/{m['repo']}/resolve/main/{m['file']}?download=true"
        out.append(m)
        print(f"{m['id']:14} {m['bytes'] / 1e9:5.2f} GB  {m['sha256'][:12]}")
    OUT.write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
