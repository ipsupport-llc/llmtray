#!/bin/bash
# Reproduce results/: parity, bench, runner tests. One model process at a time.
# S = work dir with mlxenv/, refenv/, models/, data/, ref/ (see README).
set -e
S=${S:?set S to the work dir}
W=$(cd "$(dirname "$0")" && pwd)
cd "$S"
R=$W/registry.json
PY=mlxenv/bin/python
rm -f $W/results/parity.jsonl $W/results/bench.jsonl
par() { $PY $W/parity.py $R "$@" --json $W/results/parity.jsonl | cut -c1-400; }
par bge-m3 models/bge-m3-own-f32 data ref/bge-m3.npz --dtype float32 --label "bge-m3 own conversion (BAAI tokenizer.json), fp32"
par bge-m3 models/bge-m3-own-f32 data ref/bge-m3.npz --dtype bfloat16 --label "bge-m3 own conversion (BAAI tokenizer.json), bf16"
par bge-m3 models/bge-m3-mlx-fp16 data ref/bge-m3.npz --dtype float32 --label "mlx-community fp16 weights, fp32 compute"
par bge-m3 models/bge-m3-mlx-fp16 data ref/bge-m3.npz --label "mlx-community fp16 (default entry)"
par bge-m3-q8 models/bge-m3-mlx-8bit data ref/bge-m3.npz --label "mlx-community 8-bit"
par bge-m3-q4 models/bge-m3-mlx-4bit data ref/bge-m3.npz --label "mlx-community 4-bit"
par multilingual-e5-large-instruct models/multilingual-e5-large-instruct data ref/e5.npz --label "multilingual-e5-large-instruct fp16"
par embeddinggemma-300m models/embeddinggemma-300m data ref/embeddinggemma-300m.npz --dtype float32 --label "embeddinggemma-300m fp32"
par embeddinggemma-300m models/embeddinggemma-300m data ref/embeddinggemma-300m.npz --label "embeddinggemma-300m bf16 (entry default)"
par embeddinggemma-300m models/embeddinggemma-300m data ref/embeddinggemma-300m.npz --dtype float16 --label "embeddinggemma-300m fp16 (expected NaN)"
ben() { $PY $W/bench.py $R "$@" --json $W/results/bench.jsonl | grep -v '^{'; }
ben bge-m3 models/bge-m3-mlx-fp16 data
ben bge-m3-q8 models/bge-m3-mlx-8bit data
ben embeddinggemma-300m models/embeddinggemma-300m data --long 2048
ben multilingual-e5-large-instruct models/multilingual-e5-large-instruct data --long 512
for e in "bge-m3 models/bge-m3-mlx-fp16 ref/bge-m3.npz" "embeddinggemma-300m models/embeddinggemma-300m ref/embeddinggemma-300m.npz"; do
  set -- $e
  $PY $W/client_test.py $R $1 $2 data $3 --verify --json $W/results/runner_$1.json | grep -v '^{'
done
