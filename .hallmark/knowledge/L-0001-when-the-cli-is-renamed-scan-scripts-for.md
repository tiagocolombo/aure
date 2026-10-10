---
id: L-0001
kind: rule
scope: ["scripts/**"]
lens: correctness
source: ["H-0001/F1"]
status: proposed
used: 0
---
# When the CLI is renamed, scan scripts for error hints and usage text that still name the old command, not just invocations.

Error messages and install hints in scripts, such as the missing-tool message in scripts/build-llama.sh, tell users which command to run, so they can point at a command that no longer exists after a rename. A review of a tool rename should grep scripts for the old CLI name in strings as well as in code paths. This finding was still open when H-0001 closed, so check that the hint was fixed before relying on it.
