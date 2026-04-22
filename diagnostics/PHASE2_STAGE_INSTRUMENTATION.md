# Phase 2 — Stage Instrumentation

## Instrumentation approach
* Added optional `LIBELLULA_STAGE_DIAG` block inside `rtl/libellula_top.v` that counts:
  - `ev_v` assertions (input events reaching `aer_rx`)
  - `lif_v` spikes (LIF layer output events)
  - OR of delay lattice taps (`v_e`…`v_sw`)
  - `ds_v`, `bg_v`, and `pred_valid`
* Counters dump a single structured line `PHASE2_STAGE …` to a user-specified log via `+STAGE_OUT`.
* Compiled `tb_pred_valid_golden` with `iverilog -DLIBELLULA_STAGE_DIAG` and ran the most permissive stimulus (GP1 settings) to capture throughput per stage.

## Observations (diagnostics/out/stage_counters.csv)
| stage | count |
|-------|-------|
| input events (`ev_v`) | 64 |
| LIF spikes (`lif_v`) | 0 |
| delay taps | 0 |
| Reichardt direction | 0 |
| Burst gate | 0 |
| Predictor | 0 |

The earliest dead stage is the **LIF tile**: despite 64 input events, `lif_tile_tmux` never produces a spike. Downstream stages remain idle accordingly.

## Implication
Either the stimulus never maps to an address that gets serviced (scan mismatch) or LIF parameters/initialization prevent any neuron from accumulating enough charge. This confirms the failure occurs before motion extraction; subsequent phases focus on interface contracts and LIF requirements.
