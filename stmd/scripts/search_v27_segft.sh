#!/bin/bash
# v27 ride-along: segmentation objective with a false-track term, local
# refinement of v26 segmentation on train(79)+val. usage: TRAIN_DIR=... VAL_DIR=...
set -e
cd "$(dirname "$0")/.."
D=${TRAIN_DIR:?}:${VAL_DIR:?}
export EXCLUDE_FILE=splits/holdout_v26.txt OBJECTIVE=seg_ft
rm -f results/v27_segft_s*.jsonl   # archived gzipped under results/search/
B=$(cat configs/v26_segmentation.json)
python3 scripts/tune.py $D results/v27_segft_s1.jsonl 150 71 "$B" 0.15 > /dev/null
B2=$(python3 scripts/best.py results/v27_segft_s*.jsonl   # archived gzipped under results/search/ | tail -1)
python3 scripts/tune.py $D results/v27_segft_s2.jsonl 100 72 "$B2" 0.07 > /dev/null
python3 scripts/best.py results/v27_segft_s*.jsonl   # archived gzipped under results/search/ | tail -1 > configs/v27_segmentation_ft.json
python3 scripts/best.py results/v27_segft_s*.jsonl   # archived gzipped under results/search/ | head -1
