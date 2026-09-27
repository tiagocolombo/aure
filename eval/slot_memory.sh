#!/bin/bash
# Resident memory of llama-server with 1 vs 4 parallel slots (4096 tokens each).
# usage: eval/slot_memory.sh MODEL.gguf
MODEL="$1"
BIN="$(dirname "$0")/../build/llama/llama-server"
for np in 1 4; do
  "$BIN" -m "$MODEL" --host 127.0.0.1 --port 18085 -c $((4096 * np)) -ngl 0 -t 6 --jinja --no-webui -np $np \
    > "/tmp/mem-$np.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 90); do curl -sf http://127.0.0.1:18085/health > /dev/null && break; sleep 1; done
  echo "slots=$np RSS=$(( $(ps -o rss= -p $PID) / 1024 )) MB"
  kill $PID
  wait $PID 2> /dev/null
done
