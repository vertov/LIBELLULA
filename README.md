# LIBELLULA 

Synthesizable RTL pipeline for real-time target tracking on Address-Event Representation (AER) / DVS event-camera output.

---

## What It Is

LIBELLULA is a single-clock synchronous pipeline that converts a raw AER event stream into pixel-coordinate predictions with 5-cycle latency at 200 MHz. It requires no frame accumulation and no CPU in the critical path.

The architecture is derived from the dragonfly small-target motion detector (STMD) circuit: leaky integrate-and-fire (LIF) neurons tile the sensor plane, a retinotopic delay lattice measures directional correlation between adjacent tiles, and an α-β predictor produces sub-pixel position estimates. A configurable N-target tracker pool extends the design to multi-target scenarios.

The implementation is Verilog-2001, vendor-neutral, and verified against a 23-requirement traceability matrix with a 34-bench core simulation suite plus a 4-bench AXI4-Stream layer (111 assertions).

---

### Design Philosophy: The Pure Motion Processor
LIBELLULA is architected as a **Pure Motion Processor**. It is intentionally decoupled from platform-specific sensors and IMU data. By operating strictly on the normalized AER stream, the core remains a general-purpose, high-speed motion engine applicable to both fixed and mobile platforms. 

For UAV applications involving significant ego-motion, it is recommended to implement platform-specific Global Motion Compensation (GMC) as a pre-filtering stage. This modular approach preserves the core's 5-cycle deterministic latency while allowing for custom integration with specific IMU/Flight Controller stacks.

----------
## Why Event-Camera / DVS Engineers Should Care

Standard frame-based vision pipelines impose a floor latency equal to the frame period (typically 1–33 ms). For high-speed intercept, collision avoidance, or sub-millisecond servo loops, that floor is a fundamental constraint, not an implementation detail.

LIBELLULA operates directly on the AER protocol that DVS sensors (Davis240, DAVIS346, Prophesee Metavision, Samsung DVS, IMX636) natively produce. There is no frame buffer, no debayer step, and no resampling. An event enters the pipeline and a prediction exits in 5 clock cycles — 25 ns at 200 MHz.

What the pipeline adds beyond raw event relay:
- Spatial grouping into configurable tile sizes via time-multiplexed LIF
- Directional motion detection via an 8-direction Reichardt correlator
- Noise suppression via the burst gate (event-density hysteresis)
- Predictive filtering via α-β tracking in Q8.8 fixed-point

All of these are synthesizable, use no floating-point hardware, and target FPGAs or standard-cell ASIC without modification.

---

## Architecture

```
                      LIBELLULA Core v22 — 6-Stage Synchronous Pipeline
 ──────────────────────────────────────────────────────────────────────────────────
  AER Input          LIF Layer           Delay Lattice       Motion Detect
  ──────────         ──────────          ─────────────       ─────────────
  aer_rx             lif_tile_tmux       delay_lattice_rb    reichardt_ds
  · level-sensitive  · time-mux LIF      · 8-direction       · signed card+diag
  · combinational    · spatial tile hash · STEP=1 tile idx   · v_w=East, v_e=West
  · ev_valid=aer_req · HIT_WEIGHT param  · ring-buffer FIFO  · leaky integration
        +0                 +2                   +3                  +4
 ──────────────────────────────────────────────────────────────────────────────────
  Density Gate        Tracker Pool + Predictor              AXI4-S Output
  ────────────        ────────────────────────              ─────────────
  burst_gate          tracker_pool → ab_predictor×N         axi4s_pred_wrapper
  · ev_cnt gate       · L1-distance routing                 · depth-4 FIFO
  · TH_OPEN/CLOSE     · idle-pool spawn (ASSIGN_TH=96 px)   · fast-path bypass
  · large WINDOW      · coast counter (COAST_TIMEOUT=4)     · ARM IHI 0051A
  · VEL_INIT guard    · VEL_INIT cold-start preload         · 48-bit TDATA
        +5                         +6
 ──────────────────────────────────────────────────────────────────────────────────
```

**Spatial tile hash:** `{in_x[XW-1:XW-HX], in_y[YW-1:YW-HY]}` — locality-preserving, required for Reichardt adjacency. XOR hashes are not locality-preserving and break direction detection.

**Exact-coordinate path:** LIF carries original AER pixel coordinates in parallel with tile indices. Predictor output (`x_hat`/`y_hat`) is sub-tile accurate in Q8.8 fixed-point.

**Activity-proportional power:** LIF is time-multiplexed; burst gate blocks the predictor during low-activity periods. Power scales sub-linearly with scene event rate.

---

## Repository Structure

```
LIBELLULA_Core_v22/
├── rtl/
│   ├── libellula_top.v          Top-level — core pipeline, all tuning parameters
│   ├── libellula_soc.v          UAV SoC wrapper (AXI4-S in/out, 64-bit TDATA)
│   ├── aer_rx.v                 AER receiver — combinational, level-sensitive
│   ├── lif_tile_tmux.v          Time-multiplexed LIF neuron array
│   ├── delay_lattice_rb.v       8-direction retinotopic delay lattice (ring buffer)
│   ├── reichardt_ds.v           8-direction Reichardt motion detector
│   ├── burst_gate.v             Event-density gate with hysteresis
│   ├── tracker_pool.v           N-target tracker pool (L1 routing, coast counter)
│   ├── ab_predictor.v           α-β predictor, Q8.8, outlier rejection, VEL_INIT, velocity zeroing on direction reversal
│   ├── conf_gate.v              Confidence scoring
│   ├── axi4s_to_aer.v           AXI4-Stream → AER bridge (SoC input)
│   └── axi4s_pred_wrapper.v     Prediction → AXI4-Stream bridge (SoC output)
│
├── tb/                          Core and integration testbenches
│   ├── tb_formal_props.v        Bounded formal: 5 properties, 50 K cycles, LFSR stimulus
│   ├── tb_golden_gen.v          Golden vector generator (freezes expected.txt)
│   ├── tb_replay_lockstep.v     Bit-exact replay against frozen golden vectors
│   ├── tb_coverage_full.v       Full-scenario VCD dump for toggle coverage analysis
│   └── ...                      (18 additional scenario and unit benches)
│
├── tb_hostile/                  Failure-mode / stress testbenches
│   ├── tb_reset_midstream_top.v Reset suppression + deterministic re-entry
│   ├── tb_aer_req_stuck_high.v  Stuck-REQ graceful handling
│   └── tb_random_stress_top.v   50 000-event random stimulus stress
│
├── sim/
│   └── Makefile                 Full build orchestration (see Build section)
│
├── tools/
│   ├── coverage_report.py       VCD toggle-coverage parser and report generator
│   └── req_trace.py             Requirements-to-evidence traceability report
│
├── diagnostics_full/            Full characterisation logs and repair history
├── doc/                         Design notes, CLAIMS.md
└── build/                       Generated artifacts (created by make targets)
    ├── golden/                  Frozen stimulus and expected output vectors
    ├── eval_package/            Packaged evaluation artifacts
    ├── req_trace.md             Generated requirements traceability table
    ├── toolchain_manifest.txt   Simulator versions + RTL source hashes
    ├── SHA256SUMS.txt           Checksum manifest for all release artifacts
    └── RELEASE_TAG.txt          Immutable release tag
```

---

## Build and Test

### Prerequisites

- **Icarus Verilog** ≥ 12.0 (`iverilog`, `vvp`)
- **Verilator** ≥ 5.038 (for `make lint` only)
- **Python** ≥ 3.8 (for `make coverage_report`, `make req_trace`)
- `shasum` / `sha256sum` (for `make sha256`, `make toolchain_manifest`)

```bash
cd sim
```

### Core simulation

```bash
make test               # 34 core benches — run this first
make axi                # 111 AXI-layer assertion benches
make scenarios          # 20 scenario benches (verbose subset of make test)
make units              # 8 unit-level benches
```

Expected output:
```
make test   →  ALL TESTS PASSED x3 core + full suite + hostile
               (3 claim benches x3 + 8 units + 20 scenarios + 3 hostile = 34 distinct benches)
make axi    →  AXI TESTS PASSED
               (tb_axi4s_to_aer 49/0 | tb_axi4s_wrapper 27/0 | tb_axi4s_pred_burst 33/0 | tb_axi4s_integration 0 mismatches)
```

### Release-quality targets

```bash
make lint               # Verilator --lint-only -Wall; zero warnings required
make formal             # Bounded simulation: 5 properties × 50 K cycles (no sby/yosys)
make golden_vectors     # Freeze stimulus + expected output to build/golden/
make replay_lockstep    # Bit-exact replay against frozen golden vectors
make coverage_report    # Toggle/FSM coverage from VCD; 70% threshold for PASS
make req_trace          # Map 23 requirements to bench/property/wave evidence
make toolchain_manifest # Log simulator versions + SHA-256 of all RTL sources
make package_eval       # Assemble evaluation package in build/eval_package/
make sha256             # Checksum manifest for RTL, benches, vectors, docs
make tag_release        # Write immutable release tag to build/RELEASE_TAG.txt
```

Run in order for a full release build:

```bash
make test && make axi && make lint && make formal && \
make golden_vectors && make replay_lockstep && \
make coverage_report && make req_trace && \
make toolchain_manifest && make package_eval && \
make sha256 && make tag_release
```

---

## Validated Performance Claims

All claims below are backed by simulation evidence in the test suite. Scope notes are explicit.

| Claim | Bench | Result |
|-------|-------|--------|
| Pipeline latency ≤ 5 cycles at 200 MHz | `tb_latency` | LATENCY_CYCLES=5, measured |
| Prediction error ≤ ±2 px, constant-velocity motion | `tb_px_bound_300hz` | 0 violations over 300 Hz stream |
| 1 Meps sustained throughput, zero event drops | `tb_aer_throughput_1meps` | 2000/2000 ACK=REQ |
| pred_valid and conf_valid suppressed during reset | `tb_reset_midstream_top` | 0 valid leaks over 266-cycle reset |
| Deterministic re-entry after reset | `tb_reset_midstream_top` | Phase-1/phase-2 outputs bit-exact |
| state_mem cleared after 2^AW reset cycles | `tb_formal_props` (P3) | All 256 cells verified |
| No X/Z on output ports, any stimulus | `tb_formal_props` (P2) | 50 K cycles, LFSR seed 0xDEADBEEF |
| Output saturation: upper bits zero on pred_valid | `tb_formal_props` (P4) | Holds for all observed states |
| Two identically-stimulated DUTs bit-exact | `tb_deterministic_replay` / `tb_formal_props` (P5) | Zero divergence |
| Clutter rejection: MAE ≤ baseline under background | `tb_cross_clutter` | Holds for 8-tile clutter scenario |
| AER handshake: aer_ack mirrors aer_req within 1 cycle | `tb_aer_rx` | 6 test cases including back-to-back |
| Both polarities accepted and passed through | `tb_coverage` | pol0_cnt>0, pol1_cnt>0 |
| Bit-exact replay against frozen golden vectors | `tb_replay_lockstep` | 18/18 hex-exact |
| Lint-clean RTL (zero Verilator warnings) | `make lint` | 0 warnings (PROCASSINIT suppressed globally; WIDTHTRUNC suppressed inline with safety proof; WIDTHEXPAND fixed structurally) |
| Pipeline survives 50 000-event random stress | `tb_random_stress_top` | No X on outputs, no stuck valids |
| NTRACK=4 predictions survive AXI backpressure | `tb_axi4s_pred_burst` | 33/33 assertions PASS |
| ARM IHI 0051A TVALID stability | `tb_axi4s_pred_burst` case 5 | PASS |
| AXI4-S beats reach aer_rx intact | `tb_axi4s_integration` | 16/16 events |
| Direction reversal peak error | `tb_reversal` (`make reversal`) | East max_err=16 px, West max_err=16 px; mean_err=0; converges to ≤1 px within 5 updates |
| **UAV parameter profile** | Application rationale documented | **APP-RECOMMENDED — not silicon-verified** |

Full requirements traceability: `make req_trace` → `build/req_trace.md` (23 requirements, REQ-01 through REQ-23).

---

## Parameters

### `libellula_top` — Core Pipeline

| Parameter | Default | Description |
|-----------|---------|-------------|
| `XW` | 10 | Sensor X width (bits) |
| `YW` | 10 | Sensor Y width (bits) |
| `AW` | 8 | LIF tile address width (2^AW tiles) |
| `DW` | 6 | Delay lattice depth (2^DW ring entries) |
| `PW` | 16 | Prediction output coordinate width |
| `NTRACK` | 1 | Tracker instances (1 = single legacy predictor) |
| `ASSIGN_TH` | 96 | New-tracker L1-distance threshold (pixels) |
| `COAST_TIMEOUT` | 4 | Missed updates before tracker retirement |
| `LIF_LEAK_SHIFT` | 4 | LIF membrane leak: state -= state >> LIF_LEAK_SHIFT |
| `LIF_THRESH` | 16 | LIF firing threshold |
| `LIF_HIT_WEIGHT` | 1 | Charge deposited per accepted event (saturating) |
| `BG_TH_OPEN` | 2 | Burst gate open threshold (event count) |
| `BG_TH_CLOSE` | 1 | Burst gate close threshold (hysteresis) |
| `BG_WINDOW_OVR` | 0 | 0 = auto large window (1<<AW+12); >0 = explicit override |
| `VEL_INIT` | `TILE_STEP_PX` | Cold-start velocity pre-load magnitude (pixels, Q8.8) |
| `VEL_SAT` | `TILE_STEP_PX*2` | Velocity saturation limit (auto-scales with AW) |

**VEL_INIT invariant:** `BG_TH_OPEN=2` blocks the first `ds_v` pulse (when no direction is yet established). The first `bg_v` is the second `ds_v`, at which point `dir_x/dir_y` are valid and `VEL_INIT` fires correctly. Lowering `BG_TH_OPEN` or overriding `BG_WINDOW_OVR` with low event density can break this invariant. Verify with your event camera's event rate before changing these defaults.

### `axi4s_pred_wrapper` — Prediction Output Bridge

| Parameter | Default | Description |
|-----------|---------|-------------|
| `PW` | 16 | Prediction coordinate width (must match `libellula_top`) |
| `CONFW` | 8 | Confidence output width |
| `FIFO_DEPTH` | 4 | Overflow FIFO depth (power of 2; set ≥ NTRACK) |

### `libellula_soc` — UAV SoC Wrapper

| Parameter | Default | Rationale |
|-----------|---------|-----------|
| `AW` | 8 | 256-tile spatial resolution |
| `DW` | 6 | 64-event temporal window |
| `NTRACK` | 4 | 4-target pool |
| `LIF_LEAK_SHIFT` | 14 | 99.99% membrane retention per scan bucket |
| `LIF_THRESH` | 4 | Hair-trigger for sparse distant-target events |
| `LIF_HIT_WEIGHT` | 8192 | Single event charges membrane to threshold |
| `BG_TH_OPEN` | 1 | Gate opens on first density signal |
| `BG_TH_CLOSE` | 0 | Gate stays open (continuous target assumption) |
| `BG_WINDOW_OVR` | 4 | Short window for fast-moving sparse targets |

---

## AXI4-Stream Integration

### Input: `axi4s_to_aer`

Converts AXI4-Stream event beats to AER handshake for `libellula_top`. Throughput: 1 event per 2 clock cycles.

**TDATA packing (32-bit):**
```
  [31 : XW+YW+1]   reserved
  [XW+YW]          pol        event polarity
  [XW+YW-1 : XW]   y          Y pixel coordinate
  [XW-1 : 0]       x          X pixel coordinate
```

### Output: `axi4s_pred_wrapper`

Converts `pred_valid` strobes to an AXI4-Stream master with a depth-4 FIFO for backpressure absorption. Fast-path bypass preserves single-cycle latency when the FIFO is empty and the output is idle.

**TDATA packing (48-bit):**
```
  [47:40]   8'b0         reserved
  [39:32]   conf[7:0]    confidence score
  [31:16]   y_hat[15:0]  Y prediction (Q8.8 fixed-point)
  [15: 0]   x_hat[15:0]  X prediction (Q8.8 fixed-point)
```
`TKEEP = 6'b111111`  `TLAST = TVALID`  (single-beat frame per prediction)

### SoC wrapper: `libellula_soc`

Full AXI4-S in/out with internal scan counter. No external scan pin required.

**TDATA packing (64-bit):**
```
  [63:48]   16'b0            reserved
  [47:46]   track_id[1:0]    tracker index
  [45:40]   6'b0             reserved
  [39:32]   conf[7:0]        confidence
  [31:16]   y_hat[15:0]      Y prediction (Q8.8)
  [15: 0]   x_hat[15:0]      X prediction (Q8.8)
```
`TKEEP = 8'hFF`  `TLAST = TVALID`

Reset convention: `libellula_top` uses active-high `rst`; AXI bridges use active-low `rst_n`; `libellula_soc` handles the inversion internally.

### Minimal instantiation

```verilog
// Single-target core with AXI4-S output
libellula_top #(
    .NTRACK        (1),
    .LIF_LEAK_SHIFT(4),
    .LIF_THRESH    (16),
    .BG_TH_OPEN    (2)
) u_core (
    .clk       (clk),
    .rst       (rst),
    .aer_req   (aer_req),
    .aer_ack   (aer_ack),
    .aer_x     (aer_x),
    .aer_y     (aer_y),
    .aer_pol   (aer_pol),
    .scan_addr (scan_counter),
    .pred_valid(pred_valid),
    .x_hat     (x_hat),
    .y_hat     (y_hat),
    .conf      (conf),
    .conf_valid(conf_valid),
    .track_id  (track_id)
);

axi4s_pred_wrapper #(
    .FIFO_DEPTH(4)
) u_wrap (
    .clk           (clk),
    .rst_n         (rst_n),
    .pred_valid    (pred_valid),
    .x_pred        (x_hat),
    .y_pred        (y_hat),
    .conf          (conf),
    .m_axis_tvalid (m_tvalid),
    .m_axis_tready (m_tready),
    .m_axis_tdata  (m_tdata),
    .m_axis_tkeep  (m_tkeep),
    .m_axis_tlast  (m_tlast)
);

// For the full UAV SoC path (AXI4-S in + out, 64-bit TDATA, track_id):
// use libellula_soc directly
```

---

## Evaluation / Integration Path

A pre-packaged evaluation artifact set is generated by `make package_eval`:

```
build/eval_package/
├── README_eval.md          Entry point for evaluators
├── interface_spec.md       Port list, TDATA packing, timing diagrams (text)
├── latency_spec.md         5-cycle latency measurement methodology
├── verified_claims.md      Validation claims with bench citations
├── known_limits.md         Explicit current limitations
├── req_trace.md            23-requirement traceability table
├── toolchain_manifest.txt  Simulator versions + RTL source SHA-256s
└── SHA256SUMS.txt          Checksum manifest for all package files
```

For integration evaluation:

1. Run `make test` and verify all 34 core benches pass.
2. Run `make lint` and verify zero Verilator warnings.
3. Run `make formal` to verify the 5 bounded properties hold over 50 K cycles.
4. Run `make golden_vectors` to freeze a golden reference, then `make replay_lockstep` to confirm bit-exact replay on any RTL revision.
5. Run `make package_eval` and review `build/eval_package/` for interface and performance documentation.

---

## Current Status and Limitations

| Area | Status |
|------|--------|
| Core pipeline RTL | Complete. 34-bench core suite all green (3 claim × 3 runs + 8 units + 20 scenarios + 3 hostile). |
| AXI4-S integration | Complete. 111-assertion suite all green. |
| Lint (Verilator -Wall) | Zero warnings. PROCASSINIT suppressed globally (valid init pattern); WIDTHTRUNC suppressed inline with safety comments; WIDTHEXPAND fixed structurally. |
| Formal verification | Bounded simulation equivalent (50 K cycles, LFSR). Not SymbiYosys/Yosys full formal — those tools are not available in the current toolchain. REQ-07/08/09 are verified via `make formal`, not unbounded model checking. |
| Synthesis | RTL is vendor-neutral Verilog-2001. Not synthesis-tested against a specific FPGA or cell library in this release. No timing closure report is included. |
| Silicon verification | No tape-out or FPGA bitstream in this release. All claims are simulation-based. |
| UAV parameter profile | Application-recommended starting points. Not validated against a physical event camera or a target at range. |
| CDC | Single-clock design. No CDC paths. Confirmed by code review and Verilator lint. No formal CDC analysis tool has been run. |
| Power | Activity-proportional by construction (time-mux LIF + burst gate). No switching power estimate or synthesis power report is included. |
| Multi-target validation | NTRACK=4 pool tested in simulation. Maximum sustainable target count under realistic clutter has not been characterized. |

### Known design constraints

- **Scan address:** `libellula_top` requires an external free-running `scan_addr` counter of width `AW`. `libellula_soc` provides this internally; bare `libellula_top` instantiations must drive it.
- **Tile hash:** Only the spatial hash (`{x[XW-1:XW-HX], y[YW-1:YW-HY]}`) is supported. XOR hashes break the Reichardt adjacency assumption.
- **DW=0:** Legal and tested. All delay-lattice ring buffers collapse to depth-1 (combinational). Used in hostile benches where pipeline drain timing matters.
- **BG_TH_CLOSE=0:** Gate never closes once opened. Valid for continuous-motion scenarios; inappropriate for scenes with frequent target disappearance.
- **Direction reversal RTL floor (~16 px peak):** The predictor zeros accumulated velocity the cycle it observes a sign flip in `dir_x/dir_y`. However, the Reichardt accumulator requires approximately one integration cycle after the physical reversal before its output crosses zero. The first post-reversal measurement therefore arrives with `dir_x` still pointing in the old direction, so `reversal_x` does not fire until the second update. This produces a single-measurement overshoot of ~16 px (one tile width for AW=8) that decays to ≤1 px within 5 updates. Reducing this further would require an upstream reversal signal or lowering `REVERSAL_TH` below the noise floor — both carry tradeoffs. Pre-fix overshoot was 26 px; 16 px is the architectural floor for this pipeline topology.

---

## Simulation-Only Instrumentation

Compile with `-DLIBELLULA_DIAG` (iverilog only — do not pass to vvp) to enable CDX diagnostic counters in `lif_tile_tmux`: `events_presented`, `events_accepted`, `events_retimed`, `lif_updates`, `lif_spikes`. These synthesise away cleanly.

---

## Toolchain

Tested with:
- Icarus Verilog 12.0 (simulation)
- Verilator 5.038 (lint only)
- Python 3.x (coverage_report.py, req_trace.py)

Run `make toolchain_manifest` to log exact versions and RTL source SHA-256 checksums to `build/toolchain_manifest.txt`.

---


## Contact

oliver.hockenhull@gmail.com

---

*Architecture inspired by the small-target motion detector (STMD) circuit of the dragonfly (*Libellula*), characterised by Wiederman, O'Carroll, and collaborators.*
