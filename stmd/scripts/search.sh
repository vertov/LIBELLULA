#!/bin/bash
# Three-stage random search on val. usage: search.sh TAG [FIXED_JSON]
set -e
cd "$(dirname "$0")/.."
V=${VAL_DIR:?set VAL_DIR to the EV-UAV val folder}
TAG=$1; FIX=${2:-"{}"}
rm -f results/${TAG}_s*.jsonl
python3 scripts/tune.py $V results/${TAG}_s1.jsonl ${N1:-300} 1 - 1.0 "$FIX" > /dev/null
B=$(python3 scripts/best.py results/${TAG}_s*.jsonl | tail -1)
python3 scripts/tune.py $V results/${TAG}_s2.jsonl ${N2:-200} 2 "$B" 0.15 "$FIX" > /dev/null
B=$(python3 scripts/best.py results/${TAG}_s*.jsonl | tail -1)
python3 scripts/tune.py $V results/${TAG}_s3.jsonl ${N3:-150} 3 "$B" 0.08 "$FIX" > /dev/null
python3 scripts/best.py results/${TAG}_s*.jsonl | tail -1 > results/config_${TAG}.json
echo "$TAG: $(python3 scripts/best.py results/${TAG}_s*.jsonl | head -1)"
