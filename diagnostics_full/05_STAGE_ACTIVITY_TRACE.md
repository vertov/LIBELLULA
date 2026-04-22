# Phase 4 — Stage Activity Trace

**Independent verification 2026-04-11.**

Both canonical benches re-run directly with `LIBELLULA_STAGE_DIAG`. Stage log written to `diagnostics_full/out/stage_golden.log` and `stage_must_fire.log`.

---

## Commands

```bash
make -C sim build/tb_pred_valid_golden IVERILOG="iverilog -DLIBELLULA_STAGE_DIAG"
vvp sim/build/tb_pred_valid_golden +TEST_NAME=full_gp +EVENT_SPACING=1 +EVENT_COUNT=64 \
  +RESET_CYCLES=64 +QUIET_CYCLES=32 +STAGE_OUT=diagnostics_full/out/stage_golden.log

make -C sim build/tb_pred_must_fire IVERILOG="iverilog -DLIBELLULA_STAGE_DIAG"
vvp sim/build/tb_pred_must_fire +X_STEP=1 +STAGE_OUT=diagnostics_full/out/stage_must_fire.log
```

---

## Stage Activity Results

| Run | Events presented | Events accepted (ev_v) | LIF spikes (lif_v) | Delay taps | Reichardt | Burst | Pred |
|-----|-----------------|------------------------|---------------------|-----------|-----------|-------|------|
| golden_unscheduled | 64 | **64** (first_ev=33) | **0** | 0 | 0 | 0 | 0 |
| must_fire_aligned | 64 | **64** (first_ev=305) | **0** | 0 | 0 | 0 | 0 |

Raw stage log (golden):
```
PHASE2_STAGE events=64 lif=0 delay=0 reichardt=0 burst=0 pred=0
             first_ev=33 first_lif=-1 first_delay=-1 first_reichardt=-1
             first_burst=-1 first_pred=-1
```

---

## Key Observation

AER receiver (`aer_rx`) accepts ALL events — `ev_v` fires 64 times starting at cycle 33. The event data reaches `lif_tile_tmux.in_valid`. But `lif_v` (lif_tile_tmux.out_valid) never fires. The pipeline is not stalled or blocked before the LIF; the LIF actively receives events but cannot produce spikes due to the parameter mismatch proven in Phase 2.

**Earliest dead stage: `lif_tile_tmux` — specifically the spike-detection comparator `st_next >= THRESH` which never evaluates true.**

All later stages (delay_lattice, reichardt, burst_gate, ab_predictor) remain permanently at default-zero state. They have never processed a single input during any simulation run in this diagnostic.
