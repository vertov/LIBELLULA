# LIBELLULA Core v23 — Claims Traceability (Bench → Measurement Point → Assumptions)

This table ties each externally-stated technical claim to:
- the specific RTL bench that supports it,
- the exact boundary/measurement point being asserted,
- the key assumptions and parameter settings required for the claim to hold.

> Scope note: these are **RTL-simulation** claims. Silicon/FPGA timing, power, I/O electricals, and sensor/system effects are out of scope.

---

## A. Timing / Latency

| Claim (external) | What is actually proven | Bench | Measurement points | Required assumptions / knobs | What is NOT proven |
|---|---|---|---|---|---|
| **”5-cycle fixed latency @ 200 MHz (25 ns)”** | Pipeline latency from the clock edge that samples `aer_req` to first assertion of `pred_valid` under a permissive “latency posture” | `tb/tb_latency.v` | Start: `posedge clk` when `aer_req==1` is sampled by `aer_rx`. Stop: first cycle where `pred_valid==1`. The bench prints `LATENCY_CYCLES` and fails if `>5` (actual measured: 5 cycles; v22 failed only above 12). | Bench forces: `dut.u_lif.LEAK_SHIFT=0`, `dut.u_lif.THRESH=1` (LIF fires immediately) and `dut.u_bg.COUNT_TH=0` (burst gate transparent). Also uses `DW=0` (minimal delay lattice). `scan_addr` is driven but ignored under the default `LIF_SCAN_MODE=1`. | Any latency contribution from realistic LIF scanning schedules, non-transparent burst gating, deeper delay lattice (`DW>0`), multi-target interference, or backpressure (none exists) |
| **“5-cycle latency, default parameters”** (v23) | Every prediction emitted under default parameters appears ≤ 5 cycles after the newest event presented before it | `tb/tb_latency_default.v` | Same start/stop convention as `tb_latency`, applied to each `pred_valid`. Also reports events before the first prediction (32) and events per prediction (~17), not asserted. | Default LIF/burst-gate parameters, `DW=0`, single slow target (+1 px/event, 667-cycle spacing), single-cycle REQ pulses. | That every event produces a prediction (most do not under defaults); latency under multi-target load, DW>0, or bursty input |

---

## B. Bounded Error / Tracking Stability

| Claim (external) | What is actually proven | Bench | Measurement points | Required assumptions / knobs | What is NOT proven |
|---|---|---|---|---|---|
| **“±2 px one-step error, constant velocity”** (v23; replaces “±2 px at 300 Hz”) | Under a synthetic constant-velocity stimulus (+1 px per event in X), each post-warmup `x_hat` is within 2 px of the NEXT event position, and mean error is below the echo baseline (1 px). Measured: mean 0.73 px, max 2 px | `tb/tb_px_bound.v` | Compares `x_hat/y_hat` with the next true position after each event; fails on any violation after 8 warm-up predictions, on any event without a prediction, or if mean error ≥ echo baseline. | LIF fires on first hit, `DW=0`, single-cycle REQ pulses. Event cadence `PERIOD_CYC=667` at 200 MHz = 3.3 μs (~300 k events/s). v22 described this cadence as ~300 Hz in error and scored against the current position. | Error at 2–3 px/event (bound exceeded, max 3–4 px) or at 300 events/s (within bound but no better than echo) — see `make pxbound-char`; accelerations, clutter, realistic LIF/gate settings, real sensor noise |

---

## C. Throughput / Ingress

| Claim (external) | What is actually proven | Bench | Measurement points | Required assumptions / knobs | What is NOT proven |
|---|---|---|---|---|---|
| **“Sustains 1 Meps”** | That the ingress handshake path accepts a burst of events without the bench observing missing acknowledgements | `tb/tb_aer_throughput_1meps.v` | Bench emits a fixed number of events and checks that expected acknowledgements occur; intended to demonstrate no internal corruption under the chosen event schedule. | Depends on the *simplified* `aer_rx` semantics (level-sensitive req sampled on clock, 1-cycle ack). External sources must hold address stable while `aer_req=1` and deassert within one cycle of seeing `aer_ack` to avoid duplicates. | A true 4-phase AER receiver, metastability/CDC, electrical timing, or any internal backpressure semantics (none exist). Also does not prove that every event meaningfully influences downstream stages (LIF may not spike each event). |

---

## D. “No Drop” / Overload Semantics

| Claim (external) | What is actually proven | Bench | Measurement points | Required assumptions / knobs | What is NOT proven |
|---|---|---|---|---|---|
| **“No dropped events” (strong claim)** | In the current RTL, there is no explicit FIFO “drop” flag; overload is handled implicitly (e.g., ring-buffer overwrite, burst gating). Existing benches primarily demonstrate stable operation under dense patterns rather than a formal “no drop” guarantee. | `tb/tb_meps_nodrop.v` (and dense/burst benches) | Bench intent is to stress dense ingress and confirm sane outputs (implementation-specific). | Must define what “drop” means for this architecture (accepted at ingress vs. influences predictor). | A strict lossless guarantee is not established at the architectural level because several stages intentionally discard information (burst_gate) or overwrite history (ring buffer). |

---

## E. Power / Activity Scaling (RTL toggle proxy)

| Claim (external) | What is actually proven | Bench | Measurement points | Required assumptions / knobs | What is NOT proven |
|---|---|---|---|---|---|
| **“Event-driven power scaling”** | Toggle counts in VCD increase with higher event activity, serving as a proxy for switching activity | `tb/tb_power_lo.v`, `tb/tb_power_hi.v` + `tools/count_toggles.py` | Post-sim: counts per-signal toggles from the generated VCDs and aggregates into a CSV | Requires that the toggle counter is applied consistently and that VCD dumping is enabled in the benches | Actual silicon or FPGA power, clock tree power, I/O power, or PVT-dependent leakage |

---

## F. Determinism / Reset Robustness (failure-mode grade)

| Claim (external) | What should be proven for an evaluation-grade package | Bench | Measurement points | Required assumptions / knobs | Notes |
|---|---|---|---|---|---|
| **“Deterministic”** | Identical input sequences yield identical outputs; reset mid-stream does not produce undefined outputs and re-enters deterministically | `tb_hostile/tb_reset_midstream_top.v` (added) | Captures the first N predictor outputs after reset and compares run 1 vs run 2; asserts “no valids during reset”; checks no X/Z | Assumes single-clock domain and synchronous reset input as implemented | This is the kind of bench integrators often ask for explicitly |
| **Ingress semantics are explicit** | Behaviour under illegal/stuck inputs is documented and tested | `tb_hostile/tb_aer_req_stuck_high.v` (added) | Holds `aer_req` high and verifies that duplicates are emitted (as documented in `aer_rx.v`) | Assumes simplified AER protocol | Prevents downstream blame when a source violates the req/ack contract |
| **Random stress sanity** | No X/Z propagation under randomized burst patterns and occasional reset pulses | `tb_hostile/tb_random_stress_top.v` (added) | Monitors outputs for X/Z and checks “valids low during reset” | Not a physical sensor model—pure robustness sanity check | Useful as an early warning for uninitialized state or width/sign issues |

