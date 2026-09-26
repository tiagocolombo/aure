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

MODELS = [
    {
        "id": "qwen3-0.6b",
        "name": "Qwen3 0.6B",
        "repo": "bartowski/Qwen_Qwen3-0.6B-GGUF",
        "file": "Qwen_Qwen3-0.6B-Q4_K_M.gguf",
        "family": "qwen3",
        "summary": "Fastest and smallest. Good for quick fixes; best choice on Intel Macs.",
        "minRAMGB": 4,
        "license": "Apache-2.0",
    },
    {
        "id": "smollm2-1.7b",
        "name": "SmolLM2 1.7B",
        "repo": "HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF",
        "file": "smollm2-1.7b-instruct-q4_k_m.gguf",
        "family": "smollm2",
        "summary": "English-focused alternative with a small footprint.",
        "minRAMGB": 8,
        "license": "Apache-2.0",
    },
    {
        "id": "qwen3-1.7b",
        "name": "Qwen3 1.7B",
        "repo": "bartowski/Qwen_Qwen3-1.7B-GGUF",
        "file": "Qwen_Qwen3-1.7B-Q4_K_M.gguf",
        "family": "qwen3",
        "summary": "Best balance of quality and speed on Apple Silicon.",
        "minRAMGB": 8,
        "license": "Apache-2.0",
    },
    {
        "id": "qwen3-4b",
        "name": "Qwen3 4B",
        "repo": "Qwen/Qwen3-4B-GGUF",
        "file": "Qwen3-4B-Q4_K_M.gguf",
        "family": "qwen3",
        "summary": "Highest quality. Needs Apple Silicon with 16 GB of memory or more.",
        "minRAMGB": 16,
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
