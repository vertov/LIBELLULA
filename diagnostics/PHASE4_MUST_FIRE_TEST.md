# Phase 4 — Must-Fire Test

## Property definition
* Testbench `tb_pred_must_fire.v` now injects 64 events whose `(x,y)` hashes are **explicitly aligned** with the current `scan_addr`. For each event:
  - Compute `hash = (x ^ y) & ((1<<AW)-1)`.
  - Wait until the time-multiplexed scanner reaches `hash`.
  - Assert `aer_req` for exactly one cycle while the scanner points at that neuron.
* This realizes the minimum legal condition implied by `lif_tile_tmux`: every event is guaranteed to hit the intended neuron.
* Must-fire requirement: once reset is released and 64 aligned events are delivered, `pred_valid` must assert at least once within 256 tail cycles.

## Result
* `tb_pred_must_fire` reported `PHASE4_RESULT … status=FAIL` (see `diagnostics/out/must_fire_results.csv` / `.json`).
* Even under ideal alignment, `pred_valid_count` remained zero; no prediction ever emerged.
* Therefore the must-fire property **fails**: the implementation does not emit even when we satisfy the strictest inferred contract.

## Implication
* The blocking condition lies past the hash-alignment requirement—likely inside `lif_tile_tmux` (integration thresholds) or immediately downstream—but regardless, the design cannot yet be shown to emit under any legal stimulus.
