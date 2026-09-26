#!/usr/bin/env bash
# Run the real Aure pipeline (aure-eval) against several GGUF models.
#   eval/run-models.sh model1.gguf model2.gguf ...
set -uo pipefail
. "$(dirname "$0")/../scripts/lib.sh"
root="$AURE_ROOT"
port=18095
apple swift build --package-path "$root/Packages/AureKit" --product aure-eval >/dev/null 2>&1
bin="$(apple swift build --package-path "$root/Packages/AureKit" --show-bin-path)/aure-eval"
for m in "$@"; do
  name="$(basename "$m" .gguf)"
  "$root/build/llama/llama-server" -m "$m" --host 127.0.0.1 --port $port -c 4096 -ngl 0 \
    -t "$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.physicalcpu)" \
    --jinja --no-webui -np 1 > "/tmp/run-$name.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 120); do curl -sf "localhost:$port/health" >/dev/null && break; sleep 1; done
  echo "== $name"
  (cd "$root" && "$bin" --server "http://127.0.0.1:$port") | sed -n '/== aure-eval/,$p' | tail -6
  kill $pid; wait $pid 2>/dev/null
done
