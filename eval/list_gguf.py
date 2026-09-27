#!/usr/bin/env python3
"""List Q4_K_M (or given quant) GGUF files with sizes for candidate repos."""
import json, sys, urllib.request
repos = sys.argv[1:]
for repo in repos:
    try:
        data = json.load(urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true", timeout=30))
    except Exception as e:
        print(repo, "ERR", e); continue
    files = [d for d in data if d.get("type") == "file" and d["path"].lower().endswith(".gguf")
             and ("q4_k_m" in d["path"].lower() or "q4_0" in d["path"].lower()) and "mmproj" not in d["path"].lower()]
    for f in files:
        print(f"{repo:45} {f['path']:55} {f['size']/1e9:.2f} GB  {f.get('lfs',{}).get('oid','')[:12]}")
