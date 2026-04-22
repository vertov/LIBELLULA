# Final Root Cause Report

**Independent verification run 2026-04-11. Simulator: Icarus Verilog 12.0 / vvp.**

---

## 1. Executive Finding

The LIBELLULA predictive core never emits predictions because the LIF tile (`lif_tile_tmux`) cannot spike under default parameters. With `LEAK_SHIFT=2` and `THRESH=16`, the leaky integrate-and-fire accumulator reaches a mathematical fixed point at state=4, which is permanently below the threshold of 16. Every event presented to the system is correctly received by `aer_rx` and forwarded to `lif_tile_tmux`, but the spike condition `st_next >= 16` is never satisfied. All downstream stages (delay_lattice, Reichardt, burst_gate, ab_predictor) remain at zero for the entire duration of every simulation.

---

## 2. What Is Directly Proven

- `aer_rx` correctly accepts events: `ev_v` fires 64 times in the golden-path bench (first_ev=33), confirming the input pipeline is functional.
- `lif_tile_tmux` accumulator peaks at state=4 under continuous hash-aligned hits with scan held at target address (64 hits, LEAK_SHIFT=2, THRESH=16). Confirmed by direct simulation with Icarus Verilog 12.0.
- Mathematical fixed point: `st_next = st - (st>>2) + 1` converges to 4 starting from 0 (since 4>>2=1, net change=0). This is arithmetic fact, not simulation artifact.
- `lif_v` never fires in any simulation: golden-path, must-fire, scan-hash (all 4 modes), or parameter sweep (any LEAK_SHIFT from 0 to 3 with THRESH=16).
- Downstream stage counters (delay, reichardt, burst, pred) all register 0 in every run. Stage logs confirm first_lif=-1, first_delay=-1, ..., first_pred=-1.
- With `LEAK_SHIFT=4`, `THRESH=16`, scan held: `lif_v` does spike (first_spike=65, peak=15). This confirms the arithmetic is correct and the fix is parametric.
- `LEAK_SHIFT=2` spikes only when `THRESH <= 4` — a threshold that is not physically meaningful for motion accumulation.
- Must-fire bench (`tb_pred_must_fire`) sends events with incrementing x-coordinate, causing each event to target a different LIF neuron. No single neuron accumulates more than 1 hit, making the bench inadequate as a stress test even if the LIF could spike.

---

## 3. Earliest Blocking Mechanism

The comparator `spike = (st_next >= THRESH)` in `lif_tile_tmux.v` line 70, evaluating `st_next` which cannot exceed 4 while `THRESH=16`, never evaluates true. This is the single earliest gate in the emission path that is permanently false. Every downstream gate is a consequential zero.

---

## 4. Ranked Root-Cause Candidates

1. **LIF `LEAK_SHIFT=2` / `THRESH=16` parameter mismatch** (proven by math + simulation). The fixed-point state (4) is below threshold (16). No legal stimulus can overcome this. Minimum fix: change `LEAK_SHIFT` to 4 in the RTL instantiation.

2. **Scan/hash ingestion contract undocumented and incompletely honored in benches** (proven by scan_hash bench). The one-cycle acceptance window (1-in-256 with free-running scan) is undocumented. Even the "must-fire" and "wait-for-match" benches fail to test repeated hits to the same LIF address — they send events to a new address each time. This is a compounding secondary issue.

3. **Must-fire testbench design error** (proven by code inspection). `tb_pred_must_fire` uses `x_step=1`, routing each event to a different LIF neuron. The bench cannot fire even if LEAK_SHIFT were fixed to a working value and the scan were free-running, because no neuron ever accumulates more than 1 hit.

4. **Downstream stages never validated** (proven by all-zero stage counters). The delay_lattice, Reichardt, burst_gate, and ab_predictor are syntactically correct RTL but have never been exercised in a full-pipeline simulation. Their functional correctness under realistic stimulation is unknown.

---

## 5. Is the Current Repo Functionally Valid as a Predictive Core?

**No.**

Every diagnostic run produces `pred_valid_count=0`. The LIF tile—the first active stage in the predictive pipeline—cannot spike under default parameters, leaving the entire motion detection and prediction chain permanently idle. No latency, accuracy, or throughput claims can be verified because the predictor never produces output. The repo is not functionally valid in its current committed state.

---

## 6. Is the Implementation Repairable?

**Possibly with localized fixes.**

The RTL arithmetic is correct; the failure is a parameter mismatch. Changing `LEAK_SHIFT` from 2 to 4 in `rtl/lif_tile_tmux.v` (default parameter) or in the instantiation in `libellula_top.v` would allow the LIF to spike under controlled conditions. However, repair also requires: (1) validating that the free-running scan delivers sufficient repeated-address stimulation for real event streams; (2) verifying that downstream stages (delay_lattice through ab_predictor) produce correct outputs once LIF spikes are flowing; (3) ensuring the burst gate threshold (TH_OPEN=3) is reachable under realistic event rates. None of these have been tested. The fix is localized but validation is non-trivial.

---

## 7. Smallest Repair Experiment Worth Trying

Change `LEAK_SHIFT` default from 2 to 4 in `lif_tile_tmux.v` (line 17), recompile `tb_lif_unit_diag` with scan held, and verify that the LIF spikes within 100 cycles. Then compile `libellula_top` with the same change, send 16+ identical-coordinate events to the golden-path bench (same x, same y, same hash, repeat), and check whether `lif_v` fires. This is bounded (one parameter change, one rerun), falsifiable (lif_v either fires or does not), and does not alter any other logic.

**Exact command:**
```bash
# Change LEAK_SHIFT default in lif_tile_tmux.v line 17 from 2 to 4
# Then:
iverilog -g2012 -P tb_lif_unit_diag.P_LEAK_SHIFT=4 -P tb_lif_unit_diag.P_THRESH=16 \
  -Wall -I tb -o /tmp/lif_repair rtl/*.v tb/tb_lif_unit_diag.v
vvp /tmp/lif_repair +HIT_COUNT=64 +SCAN_MODE=0 +TARGET_ADDR=5
# Expected: spiked=1 first_spike~65
```

---

## 8. What Should Not Be Claimed Externally

- That the RTL is verified or validated. No `pred_valid` has ever been observed.
- That latency is 6 cycles (or any number). The predictor has never been triggered.
- That accuracy is ±2 pixels at 300 Hz. No predictions exist to measure.
- That 1 Meps throughput is supported. No downstream processing has been demonstrated.
- That comparison to baseline trackers is meaningful. The core produces zero outputs.
- That synthesis/OOC timing closure implies functional correctness. It does not.
- That the "must-fire" test proves the pipeline can produce predictions under stress. It does not (bench design flaw).

---

## 9. Commands Run (in order, this session)

```bash
# 1. Check simulator
which iverilog && iverilog -V 2>&1 | head -1

# 2. Build and run golden-path bench
make -C sim build/tb_pred_valid_golden IVERILOG="iverilog -DLIBELLULA_STAGE_DIAG"
vvp sim/build/tb_pred_valid_golden +TEST_NAME=full_gp +EVENT_SPACING=1 +EVENT_COUNT=64 \
  +RESET_CYCLES=64 +QUIET_CYCLES=32 +STAGE_OUT=diagnostics_full/out/stage_golden.log

# 3. Build and run must-fire bench
make -C sim build/tb_pred_must_fire IVERILOG="iverilog -DLIBELLULA_STAGE_DIAG"
vvp sim/build/tb_pred_must_fire +X_STEP=1 +STAGE_OUT=diagnostics_full/out/stage_must_fire.log

# 4. Compile and run LIF unit bench (default params)
make -C sim build/tb_lif_unit_diag
vvp sim/build/tb_lif_unit_diag +BENCH_NAME=hold_default +TARGET_ADDR=5 \
  +HIT_COUNT=64 +HIT_SPACING=0 +SCAN_MODE=0

# 5. LEAK_SHIFT sweep (0-5, THRESH=16)
for ls in 0 1 2 3 4 5; do
  iverilog -g2012 -P tb_lif_unit_diag.P_LEAK_SHIFT=$ls -P tb_lif_unit_diag.P_THRESH=16 \
    -Wall -I tb -o /tmp/lif_ls$ls rtl/*.v tb/tb_lif_unit_diag.v
  vvp /tmp/lif_ls$ls +HIT_COUNT=200 +HIT_SPACING=0 +SCAN_MODE=0 +TARGET_ADDR=5
done

# 6. THRESH sweep (LEAK_SHIFT=2)
for thresh in 1 2 4 8 16; do
  iverilog -g2012 -P tb_lif_unit_diag.P_THRESH=$thresh -P tb_lif_unit_diag.P_LEAK_SHIFT=2 \
    -Wall -I tb -o /tmp/lif_t$thresh rtl/*.v tb/tb_lif_unit_diag.v
  vvp /tmp/lif_t$thresh +HIT_COUNT=128 +HIT_SPACING=0 +SCAN_MODE=0 +TARGET_ADDR=5
done

# 7. Build and run scan/hash bench (all 4 modes)
make -C sim build/tb_scan_hash_diag
for mode in 0 1 2 3; do
  vvp sim/build/tb_scan_hash_diag +STIM_MODE=$mode +EVENT_COUNT=32
done
```
