# Phase 3 — Interface Contract Audit

## Confirmed contracts
* **Reset/clock:** single active-high synchronous `rst`, benches use `@(negedge clk)` sequencing; `libellula_top` derives all state off this clock.
* **AER handshake:** `aer_req` is level-sensitive, `aer_ack` pulses combinationally when `aer_req && !rst`; source must hold `aer_x/y/pol` stable while `aer_req=1` and drop req after one cycle (as repo benches do).
* **Scan behaviour:** `lif_tile_tmux` exposes `scan_addr` input that must continuously sweep the neuron SRAM; all official benches simply increment by 1 every cycle.
* **Event hashing:** inside `lif_tile_tmux`, each event hashes to `hashed_xy = (in_x ^ in_y) & ((1<<AW)-1)`; a spike can only occur when `scan_addr` equals this hashed index (`hit_comb = in_valid && (hashed_xy == scan_addr)`).
* **Direction/burst gating:** `delay_lattice_rb` + `reichardt_ds` consume the `lif_v` spikes; `burst_gate` only cares about sustained `ds_v` asserts, no external ready required.
* **Prediction interface:** `ab_predictor` asserts `out_valid` only when `in_valid` (from burst gate) is high and the predictor has been initialized by at least one measurement.

## Mismatches and blockers
1. **Scan-aligned injection requirement missing from harness.** Neither `tb_pred_valid_golden` nor the Python benchmark harness waits for `scan_addr` to match `hashed_xy`. Events are injected immediately, so `lif_tile_tmux` sees `in_valid=1` almost always when `hashed_xy != scan_addr`, causing `hit_comb=0`. Phase-2 counters confirmed `lif_v` never asserted even though 64 events reached `aer_rx`.
2. **No ready/back-pressure to reschedule events.** `aer_rx` accepts every event immediately; there is no mechanism to hold an event until the scanner visits the matching neuron. The only legal way to get a hit is to *time* the assertion of `aer_req` so it coincides with the `scan_addr` corresponding to that `(x,y)` hash. Existing harnesses do not attempt this scheduling.
3. **Documentation gap:** README does not state that `scan_addr` and hashed `(x,y)` must be synchronised. Without that knowledge, an external harness will never satisfy the contract.

## Unresolved uncertainties
* Minimum dwell per neuron: `lif_tile_tmux` reads/writes a single address per cycle; unclear whether multiple events can be queued for the same neuron or if hysteresis requires multiple visits.
* Burst gate thresholds (`TH_OPEN/TH_CLOSE`) values vs. expected event density—still unknown because we never reach that stage.
* Whether `aer_pol` needs to alternate for proper delay-lattice correlations (RTL accepts either, but not documented).

## Harness compatibility assessment
* **Current benchmark harness:** semantically incompatible. It emits events according to scenario time only and does not compute the hash or align to `scan_addr`. Therefore, the DUT never registers any LIF hits, and downstream stages remain inert.
* **Existing repo benches:** `tb_cv_linear` shares the same simplistic pattern, so it likely passes only because it never checks for `pred_valid`. There is no evidence of a bench that proves true emission under correct scan alignment.

**Conclusion:** the earliest blocking contract is the unspoken requirement that event injection must be synchronised with `scan_addr == (x ^ y)`. The harness violates this contract, preventing any spike, so the apparent non-emission is a contract mismatch (Category B) rather than an immediate predictor failure.
