#!/bin/bash
# Ablations: start from the frozen full config with one component removed,
# re-tune locally on val (150 configs), keep the best. Test is not touched.
cd "$(dirname "$0")/.."
V=${VAL_DIR:?set VAL_DIR to the EV-UAV val folder}
B=$(cat results/config_full.json)
run() {
  rm -f results/abl_$1.jsonl
  python3 scripts/tune.py $V results/abl_$1.jsonl 150 21 "$B" 0.15 "$2" > /dev/null
  python3 scripts/best.py results/abl_$1.jsonl | tail -1 > results/config_abl_$1.json
  echo "$1: $(python3 scripts/best.py results/abl_$1.jsonl | head -1)"
}
run no_estmd '{"use_estmd": false}'
run no_habituation '{"use_habituation": false}'
run no_surround '{"use_surround": false}'
run no_activity_surround '{"k_act": 0}'
run no_static '{"T_stat_ms": 0}'
run no_tracker '{"use_tracker": false}'
run density_only '{"use_estmd": false, "use_habituation": false, "use_surround": false}'
