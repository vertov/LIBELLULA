#!/bin/bash
# v26 tuning on train (minus held-out) + val. Two operating points.
# usage: TRAIN_DIR=... VAL_DIR=... scripts/search_v26.sh
set -e
cd "$(dirname "$0")/.."
D=${TRAIN_DIR:?}:${VAL_DIR:?}
export EXCLUDE_FILE=splits/holdout_v26.txt
B=$(cat configs/selected_v25.json)
# --- segmentation operating point (IoU + Pd), local refinement of v25
export OBJECTIVE=seg
rm -f results/v26_seg_s*.jsonl
python3 scripts/tune.py $D results/v26_seg_s1.jsonl 150 61 "$B" 0.15 > /dev/null
B2=$(python3 scripts/best.py results/v26_seg_s*.jsonl | tail -1)
python3 scripts/tune.py $D results/v26_seg_s2.jsonl 100 62 "$B2" 0.07 > /dev/null
python3 scripts/best.py results/v26_seg_s*.jsonl | tail -1 > configs/v26_segmentation.json
echo "seg: $(python3 scripts/best.py results/v26_seg_s*.jsonl | head -1)"
# --- alarm operating point (coverage + detection, false-track budget FT_BUDGET/min)
export OBJECTIVE=alarm
rm -f results/v26_alarm_s*.jsonl
python3 scripts/tune.py $D results/v26_alarm_s1.jsonl 200 63 "$B" 0.35 > /dev/null
B3=$(python3 scripts/best.py results/v26_alarm_s*.jsonl | tail -1)
python3 scripts/tune.py $D results/v26_alarm_s2.jsonl 150 64 "$B3" 0.12 > /dev/null
python3 scripts/best.py results/v26_alarm_s*.jsonl | tail -1 > configs/v26_alarm.json
echo "alarm: $(python3 scripts/best.py results/v26_alarm_s*.jsonl | head -1)"
