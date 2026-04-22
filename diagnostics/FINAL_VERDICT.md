# Final Verdict

## 1. Executive finding
Despite exhaustive golden-path stimuli, stage-level instrumentation, and a hash-aligned must-fire bench, LIBELLULA never asserted `pred_valid`; the first dead stage is the LIF tile, whose `(x ^ y)` address hashing plus free-running scan never see coincident hits, so no spikes are generated and the downstream pipeline remains silent.

## 2. What is proven
- `tb_pred_valid_golden` (Phase 1) with multiple event densities produced `pred_valid_count = 0` in every sweep (diagnostics/out/golden_path_results.csv).
- Stage counters (Phase 2) show 64 input events reach `aer_rx`, but `lif_v`, delay taps, Reichardt, burst gate, and predictor all stay at zero (diagnostics/out/stage_counters.csv).
- Contract audit (Phase 3) confirms `lif_tile_tmux` only increments a neuron when `scan_addr == (x ^ y)` during the event cycle; there is no ready/hold mechanism, so unaligned events are simply discarded.
- Even when the must-fire bench aligns each event to the hashed scan index, `pred_valid` never asserts (diagnostics/out/must_fire_results.csv).
- The LIF recurrence `state_next = (3/4) * state + 1` with `THRESH=16` cannot cross threshold when each neuron is serviced once per 256-cycle scan, so a moving target (changing `(x,y)` each event) can never produce a spike under the documented scan pattern.

## 3. What is not proven
- Whether customizing `scan_addr` (e.g., directly writing the hashed index instead of free-running) could ever yield a spike—no evidence shows this configuration is legal or functional.
- Whether alternative parameter sets (different `THRESH` or leak) might allow accumulation; current repo fixes them, and we did not alter RTL constants.
- Downstream correctness (delay lattice, burst gate, predictor) remains untested because the LIF stage never emits.

## 4. Earliest blocking stage
**LIF tile (`lif_tile_tmux`)** — evidenced by Phase 2 counters (`lif=0`) and the requirement that `scan_addr` must equal `(x ^ y)` during the single event cycle. With the provided scan pattern and thresholds, this coincidence never happens often enough to reach the spike threshold, so the pipeline stops immediately after AER reception.

## 5. Root-cause candidates ranked
1. **Scan/hash contract mismatch** — Events are injected without waiting for `scan_addr == (x ^ y)`, so almost every event is discarded at the LIF input.
2. **LIF threshold/leak configuration** — Even if alignment were fixed, the `(3/4)S + 1` recurrence under THRESH=16 cannot fire when each neuron receives at most one hit per 256-cycle scan.
3. **Downstream gating** — Not observed; all later stages remain idle because LIF never spikes.

## 6. Can the current repo validate LIBELLULA’s value claim?
**No.** Every existing bench (including the new diagnostics) fails to elicit a single prediction, so there is no timing or accuracy data to validate. The root issue is earlier than the advertised advantages: input events never make it past the LIF stage. The repository lacks any harness that satisfies the implicit scan/hash contract, and even the carefully aligned must-fire bench still cannot overcome the LIF accumulation limits. Without a demonstrably emitting configuration, all downstream claims remain unverified.

## 7. Recommended next step
**repair core logic before any more benchmarking.** The LIF stage either needs a documented, enforceable contract (e.g., a handshake or per-event addressing) or different integration parameters; until it can actually spike under a reasonable stimulus, comparative benchmarking is meaningless.
