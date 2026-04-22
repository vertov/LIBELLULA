#!/usr/bin/env python3
"""
Requirement-to-evidence traceability report for LIBELLULA Core v22.

Generates build/req_trace.md mapping each technical claim to its
verification evidence (testbench, Makefile target, property type).

Usage:
    python3 req_trace.py [output.md]
"""

import sys, os, datetime

REQ_TABLE = [
    # (req_id, claim, evidence_type, make_target, bench_file, what_is_checked)
    ("REQ-01", "Bounded latency ≤ 5 cycles @ 200 MHz",
     "Simulation", "test_latency_cycles", "tb/tb_latency.v",
     "Measures cycle count from aer_req to pred_valid; asserts LATENCY_CYCLES==5"),

    ("REQ-02", "Prediction error ≤ ±2 px under constant-velocity motion",
     "Simulation", "test_prediction_error", "tb/tb_prediction_error.v",
     "Compares x_hat/y_hat against ground-truth over 100 events; MAE ≤ 2 px required"),

    ("REQ-03", "1 Meps sustained throughput (zero event drops)",
     "Simulation", "test_max_event_rate", "tb/tb_aer_throughput_1meps.v",
     "2000 events at 1 Meps; all 2000 acknowledged, zero drops"),

    ("REQ-04", "Prediction rate ≥ 300 Hz; error ≤ ±2 px",
     "Simulation", "test_single_target_linear", "tb/tb_px_bound_300hz.v",
     "300 Hz event stream over 1 s; verifies pred_valid rate and per-frame MAE"),

    ("REQ-05", "pred_valid and conf_valid suppressed during reset",
     "Simulation + Bounded formal", "test_reset", "tb_hostile/tb_reset_midstream_top.v",
     "rst asserted mid-stream for 266 cycles; monitors every posedge for valid leak"),

    ("REQ-06", "Deterministic re-entry after reset (same stimulus → same output)",
     "Simulation", "test_reset", "tb_hostile/tb_reset_midstream_top.v",
     "Phase-1 golden captured; phase-2 replay compared sample-by-sample"),

    ("REQ-07", "state_mem fully cleared after 2^AW consecutive reset cycles",
     "Bounded formal simulation", "formal", "tb/tb_formal_props.v",
     "P3: hierarchical state_mem[] check after exactly 2^AW+5 reset cycles"),

    ("REQ-08", "No X/Z on output ports at any time",
     "Simulation + Bounded formal", "formal", "tb/tb_formal_props.v",
     "P2: 50 000-cycle LFSR stimulus; checks ^pred_valid, ^conf_valid, ^aer_ack != 1'bx"),

    ("REQ-09", "Output saturation: x_hat[PW-1:XW] = 0 when pred_valid",
     "Bounded formal simulation", "formal", "tb/tb_formal_props.v",
     "P4: checks upper bits of x_hat/y_hat are zero on every pred_valid pulse"),

    ("REQ-10", "Two identically-stimulated DUTs produce bit-exact outputs",
     "Simulation", "test_deterministic_replay", "tb/tb_deterministic_replay.v",
     "dut_a and dut_b driven in parallel; zero divergence allowed over full run"),

    ("REQ-11", "Clutter rejection: MAE under background clutter ≤ MAE baseline",
     "Simulation", "test_clutter_background", "tb/tb_cross_clutter.v",
     "40 target + 80 clutter events (8 independent tiles); MAE ≤ baseline"),

    ("REQ-12", "AER handshake: aer_ack mirrors aer_req within 1 cycle (no drops)",
     "Simulation", "test_aer_rx_decode", "tb/tb_aer_rx.v",
     "6 test cases including back-to-back events and reset-during-active"),

    ("REQ-13", "Non-sequential event coordinates accepted without error",
     "Simulation", "test_aer_timestamp_order", "tb/tb_aer_timestamp_order.v",
     "40 events with random x,y coordinates; all 40 acknowledged"),

    ("REQ-14", "Both polarities (pol=0 and pol=1) accepted and passed through",
     "Simulation", "test_coverage", "tb/tb_coverage.v",
     "40 alternating-polarity events; pol0_cnt>0 and pol1_cnt>0 verified"),

    ("REQ-15", "Zero pred_valid during idle (no events)",
     "Simulation", "test_idle_no_false_events", "tb/tb_zero_motion.v",
     "Static scene: all events at same pixel; pred_valid must not fire spuriously"),

    ("REQ-16", "aer_req stuck high handled gracefully (no pipeline stall)",
     "Hostile simulation", "test_assertions", "tb_hostile/tb_aer_req_stuck_high.v",
     "aer_req held high for 50 cycles; pipeline remains live, no X on outputs"),

    ("REQ-17", "Pipeline survives random stimulus stress (50 000 events)",
     "Hostile simulation", "test_assertions", "tb_hostile/tb_random_stress_top.v",
     "Random x,y,pol stimulus; checks no X on outputs, no stuck valids"),

    ("REQ-18", "Burst gate opens only when event density exceeds threshold",
     "Simulation", "test_gate_threshold_sweep", "tb/tb_gate_threshold_sweep.v",
     "Two DUTs: BG_TH=1 fires first; BG_TH=2 fires later; order verified"),

    ("REQ-19", "Target re-acquisition after occlusion gap",
     "Simulation", "test_occlusion_reacquire", "tb/tb_occlusion_reacquire.v",
     "20 events, 200-cycle gap, 20 events; pred_valid fires in both phases"),

    ("REQ-20", "Configurable LIF threshold separates sensitivity tiers",
     "Simulation", "test_cfg_registers", "tb/tb_cfg_registers.v",
     "THRESH=4 DUT fires after 10 events; THRESH=8 DUT does not"),

    ("REQ-21", "Lint-clean RTL (zero Verilator warnings after suppression policy)",
     "Static analysis", "lint", "(Verilator --lint-only -Wall)",
     "PROCASSINIT suppressed (valid init pattern); WIDTHTRUNC suppressed with "
     "inline comments proving safety; WIDTHEXPAND fixed structurally"),

    ("REQ-22", "Bit-exact replay against frozen golden vectors",
     "Simulation", "replay_lockstep", "tb/tb_replay_lockstep.v",
     "Reads build/golden/expected.txt; every pred_valid must match hex-exactly"),

    ("REQ-23", "Single-clock design — no CDC paths",
     "Structural inspection", "test_cdc_if_present", "(inline echo)",
     "All RTL uses a single clk domain; confirmed by code review and Verilator lint"),
]


def gen_report(out_path=None):
    now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")
    lines = []
    lines.append("# LIBELLULA Core v22 — Requirements Traceability Report")
    lines.append(f"Generated: {now}")
    lines.append("")
    lines.append("| ID | Claim | Evidence Type | `make` Target | Bench / Source | What is Checked |")
    lines.append("|:---|:------|:-------------|:-------------|:--------------|:----------------|")
    for req_id, claim, ev_type, target, bench, detail in REQ_TABLE:
        # Escape pipes in cells
        def esc(s): return s.replace('|', '\\|')
        lines.append(f"| {req_id} | {esc(claim)} | {esc(ev_type)} | "
                     f"`{esc(target)}` | `{esc(bench)}` | {esc(detail)} |")
    lines.append("")
    lines.append("## Evidence Type Key")
    lines.append("| Type | Meaning |")
    lines.append("|:-----|:--------|")
    lines.append("| Simulation | Cycle-accurate iverilog/vvp testbench; PASS/FAIL via $display |")
    lines.append("| Bounded formal simulation | As above but with exhaustive/LFSR stimulus "
                 "over ≥50 000 cycles; property holds for all observed states |")
    lines.append("| Hostile simulation | Adversarial stimulus (stuck signals, random events, "
                 "mid-stream resets); pipeline must remain live |")
    lines.append("| Static analysis | Verilator lint-only; no runtime simulation required |")
    lines.append("| Structural inspection | Single-clock design verified by code review "
                 "and absence of multi-clock constructs |")
    lines.append("")
    lines.append("## Notes")
    lines.append("- Full SVA-based formal model checking (SymbiYosys / Yosys) is not "
                 "available in this toolchain.  REQ-07, REQ-08, REQ-09 are verified via "
                 "`make formal` (bounded simulation equivalent).")
    lines.append("- All `make test_*` targets correspond to entries in this table.")
    lines.append(f"- Total requirements: {len(REQ_TABLE)}")

    text = '\n'.join(lines) + '\n'

    if out_path:
        with open(out_path, 'w') as f:
            f.write(text)
        print(f"req_trace written to {out_path}", file=sys.stderr)
    else:
        print(text)
    return text


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else None
    gen_report(out)
