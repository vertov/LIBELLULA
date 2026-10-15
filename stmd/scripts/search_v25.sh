#!/bin/bash
# v25 search on train+val (test held out). usage: VAL_DIR=... TRAIN_DIR=... search_v25.sh
set -e
cd "$(dirname "$0")/.."
D=${TRAIN_DIR:?}:${VAL_DIR:?}
rm -f results/v25_s*.jsonl
B=$(cat configs/selected_v24.json)
python3 scripts/tune.py $D results/v25_s1.jsonl 200 31 "$B" 0.0 > /dev/null      # new stages only
B=$(python3 scripts/best.py results/v25_s*.jsonl | tail -1)
python3 scripts/tune.py $D results/v25_s2.jsonl 200 32 "$B" 0.12 > /dev/null     # joint refinement
B=$(python3 scripts/best.py results/v25_s*.jsonl | tail -1)
python3 scripts/tune.py $D results/v25_s3.jsonl 150 33 "$B" 0.06 > /dev/null
python3 scripts/best.py results/v25_s*.jsonl | tail -1 > results/config_v25.json
python3 scripts/best.py results/v25_s*.jsonl | head -3
