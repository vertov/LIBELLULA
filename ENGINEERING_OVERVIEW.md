# LIBELLULA Core v22 — Engineering Overview

**Revision:** v22 (repair-patched, post-diagnostics)  
**Simulation toolchain:** Icarus Verilog 12.0 / vvp, Verilator 5.038  
**RTL language:** Verilog-2001 (`-g2012` flag required for some constructs)  
**Audience:** FPGA/ASIC engineers, DVS/event-camera integrators, potential licensees

---

## 1. What This Document Is

This document is a complete technical account of the LIBELLULA Core v22 RTL pipeline: its architecture, interface contracts, timing model, parameter space, test suite, and validated performance limits. It is based entirely on the contents of the repository — RTL source, testbench results, and diagnostic records — and distinguishes clearly between what has been measured in simulation and what has not.

Claims are cited to specific testbenches or diagnostic records. Unconstrained claims are not made.

---


## 2. Pipeline Architecture

### 2.1 Overview
LIBELLULA is a 6-stage synchronous pipeline that converts a raw AER event stream into pixel-coordinate predictions. Each stage is a separate RTL module instantiated in `rtl/libellula_top.v`. 

### 2.2 System Integration: The "Pure Motion Processor" Boundary
The LIBELLULA Core v22 is architected as a **Pure Motion Processor**. It provides high-fidelity tracking of independent motion within an AER stream but does not internally compensate for the rotational or translational ego-motion of the sensor platform (e.g., UAV yaw/pitch). 

**Integration Strategy:**
- **Fixed/Gimbaled Platforms:** The core can ingest raw DVS output directly.

- **High-Maneuver Platforms (UAVs):** A platform-specific "GMC Filter" (Global Motion Compensation) should be placed upstream of the `aer_rx` interface. This filter uses IMU data to nullify events associated with background flow, presenting a "stabilized" AER stream to the core. This approach preserves the core's vendor-neutral status and its 5-cycle timing guarantees.




```
AER handshake input
       │
  [Stage 0]  aer_rx          +0 cycles   Combinational passthrough
       │
  [Stage 1]  lif_tile_tmux   +2 cycles   Time-multiplexed LIF neuron array
       │                                  (two-stage pipeline: hash + state update)
  [Stage 2]  delay_lattice_rb +3 cycles  8-direction ring-buffer delay correlator
       │
  [Stage 3]  reichardt_ds    +4 cycles   Leaky direction-selective accumulator
       │
  [Stage 4]  burst_gate      +5 cycles   Event-density hysteresis gate
       │
  [Stage 5]  ab_predictor /  +6 cycles   α-β fixed-point predictor
             tracker_pool                 (or N-tracker pool for NTRACK > 1)
       │
  pred_valid, x_hat, y_hat, conf, conf_valid, track_id
```

**Pipeline latency measured:** 5 cycles from `aer_req` assertion to `pred_valid` assertion. Measured in `tb/tb_latency.v` with burst gate bypassed (`COUNT_TH=0`). Under normal operating parameters the burst gate introduces a hold-off period before the first prediction (see §5.3).

**Exact-coordinate parallel path:** `lif_tile_tmux` outputs both tile-grain coordinates (`out_x`, `out_y`) and the original pixel coordinates (`out_ex`, `out_ey`). The tile coordinates go forward through the delay lattice, Reichardt, and burst gate. The exact pixel coordinates are carried in a parallel delay chain (`ex_d1/ey_d1 → ex_d2/ey_d2 → ex_d3/ey_d3`) and delivered directly to the predictor. This is why prediction accuracy is sub-tile: the α-β filter operates on pixel-resolution measurements, not tile-snapped coordinates.

### 2.2 Stage-by-Stage Description

#### Stage 0: aer_rx

Fully combinational. `aer_ack = aer_req && !rst`. `ev_valid`, `ev_x`, `ev_y`, `ev_pol` are direct combinational assignments from the inputs. No registered state.

This was changed from a registered design during debugging (see `diagnostics_full/11_REPAIR_AND_VALIDATION.md`). Making aer_rx combinational reduced pipeline latency from 6 to 5 cycles and resolved a handshake timing failure in the stuck-REQ hostile test.

**Protocol contract:** The upstream source must deassert `aer_req` within 1 clock cycle of seeing `aer_ack`. One event per `aer_req` assertion; back-to-back events require separate req/ack cycles.

#### Stage 1: lif_tile_tmux

Time-multiplexed leaky integrate-and-fire neuron array. The key insight is that there is one physical state machine serving 2^AW neurons, time-multiplexed over a scan address counter.

**Tile hash (spatial, locality-preserving):**
```
HX = AW / 2
HY = AW - HX
tile_addr = {in_x[XW-1 : XW-HX], in_y[YW-1 : YW-HY]}
```
For the default parameters (AW=8, XW=10, YW=10): `tile_addr = {x[9:6], y[9:6]}` — top 4 bits of X concatenated with top 4 bits of Y. This gives a 16×16 tile grid where adjacent pixels map to adjacent tile indices. **This spatial hash is mandatory for correct Reichardt operation.** An XOR hash (`x^y`) is not locality-preserving and produces randomized adjacency that breaks direction detection.

**LIF state equation (per scan cycle):**
```
leak        = state_mem[scan_addr] >> LEAK_SHIFT
st_leaked   = state_mem[scan_addr] - leak
hit_charge  = (hit_s1) ? HIT_WEIGHT : 0
st_sum      = st_leaked + hit_charge            // (SW+1)-bit arithmetic
st_clamped  = min(st_sum, 2^SW - 1)             // saturate at 14-bit max
spike       = (st_clamped >= THRESH)
st_write    = spike ? 0 : st_clamped            // reset membrane on spike
```
`hit_s1` is the pipelined `in_valid` signal aligned to the scan address of the tile matching the incoming event.

**Minimum event count to spike:** With LEAK_SHIFT=4 (93.75% retention per scan cycle) and THRESH=16, a neuron must accumulate 16 units before it decays below threshold. With HIT_WEIGHT=1, this requires the neuron to receive at least THRESH=16 events faster than it decays. The mathematical fixed point is: `state_fp = HIT_RATE × SCAN_PERIOD / (1 - retention)`. With HIT_RATE=1 event/scan and retention=15/16, `state_fp = 16`, which equals THRESH — on the boundary. In practice at least 2 events/scan are needed for reliable spiking.

**Critical parameter history:** The original RTL shipped with LEAK_SHIFT=2 (75% retention per scan cycle). This gives a fixed point of 4 — permanently below THRESH=16 regardless of input rate. The pipeline produced zero predictions under any stimulus. Diagnosed in `diagnostics_full/00_EXEC_SUMMARY.md`, repaired by changing LEAK_SHIFT to 4. This is a fundamental architecture dependency, not a tuning note.

**Scan period:** 2^AW cycles. Default AW=8: 256-cycle scan period. At 200 MHz this is 1.28 μs. The scan_addr counter must be driven externally; `libellula_top` exposes a `scan_addr[AW-1:0]` input. `libellula_soc` drives this from an internal free-running counter.

**Reset behavior:** During `rst=1`, the state machine clears one neuron per clock cycle via the scan_addr pointer. Full clear requires 2^AW consecutive reset cycles. This is tested in `tb_formal_props.v` property P3.

**Diagnostic instrumentation:** Compiling with `-DLIBELLULA_DIAG` enables counters `events_presented`, `events_accepted`, `events_retimed`, `lif_updates`, `lif_spikes`. These synthesize away cleanly with standard synthesis pragmas. Do not pass this flag to `vvp`.

#### Stage 2: delay_lattice_rb

Ring-buffer delay line implementing 8-direction spatial correlation. For each incoming tile event, the module compares it against events stored in a ring buffer of depth 2^DW.

**Direction outputs (one-bit flags):**

| Signal | Fires when... | Implies motion direction |
|--------|---------------|--------------------------|
| `v_e` | current event at (x,y) matches buffered event at (x+1, y) | Target moved West (came from East) |
| `v_w` | current event at (x,y) matches buffered event at (x-1, y) | Target moved East (came from West) |
| `v_n` | current event at (x,y) matches buffered event at (x, y+1) | Target moved South |
| `v_s` | current event at (x,y) matches buffered event at (x, y-1) | Target moved North |
| `v_ne`, `v_nw`, `v_se`, `v_sw` | diagonal equivalents | Diagonal motion |

The naming convention follows photoreceptor source, not target direction. `v_w` fires when the delayed event came from the west of the current event, meaning the target has moved east. This inversion is corrected in `reichardt_ds`.

**DW and the delay window:** DW=6 → 64-event buffer → effective temporal window depends on event rate. At 2 events/scan (512 events/second), DW=6 gives a 128 ms window. At 1 Meps, DW=6 gives a 64 μs window. The default in the repaired RTL is DW=0 (buffer depth 1), which correlates only consecutive spikes. This was changed from DW=6 after discovering that DW=6 requires 65+ spikes before any direction correlation fires — impractical for short trajectories (10 tiles = 10 spikes). DW=0 is correct for tile-based LIF where each new spike is correlated against the immediately preceding spike.

#### Stage 3: reichardt_ds

8-direction Reichardt motion detector with leaky integration. Accumulates directional evidence over time.

**Direction encoding:**
```
v_w → dir_x += 8    (East motion)
v_e → dir_x -= 8    (West motion)
v_s → dir_y += 8    (North motion)
v_n → dir_y -= 8    (South motion)
v_nw → dir_x += 6, dir_y += 6
v_ne → dir_x -= 6, dir_y += 6
v_sw → dir_x += 6, dir_y -= 6
v_se → dir_x -= 6, dir_y -= 6
```

Cardinal weight 8, diagonal weight 6 (≈ 8/√2). This provides geometric normalization for diagonal motion.

**Leaky accumulator:**
```
acc_x -= acc_x >> DECAY_SHIFT   (every clock)
acc_y -= acc_y >> DECAY_SHIFT
```
Default DECAY_SHIFT=4 (same leak rate as LIF, 93.75% retention per cycle). The decay provides hysteresis against momentary noise and prevents direction state from persisting indefinitely after target disappearance.

**Output:** `dir_x[7:0]`, `dir_y[7:0]` — signed 8-bit, saturated at ±127. These are consumed by the predictor for velocity initialization and direction-biased velocity update.

**Characterisation result (diagnostics_full/12):** After a 6-tile constant-velocity East trajectory, `dir_x` accumulates as +8, +16, +23, stabilizing around +23 (product of 3 contributing tile transitions before decay). Direction reversal is detected within 2 tile transitions after the physical reversal occurs.

#### Stage 4: burst_gate

Hysteresis gate based on event density within a sliding window.

**Hysteresis logic:**
```
should_open  = (ev_cnt >= TH_OPEN)
should_close = (ev_cnt < TH_CLOSE)
gate_next    = gate_state ? ~should_close : should_open
```
At window boundary (win_cnt == WINDOW-1), ev_cnt resets and gate_state latches gate_next. Between boundaries, gate_state is stable (no intra-window transitions).

**Window sizing:** Default `BG_WINDOW_OVR=0` → `WINDOW = 1 << (AW + 12)` = 1,048,576 cycles at AW=8. This is a very large window (~5 ms at 200 MHz) that accumulates over many scan periods before making a gate decision. The intent is to avoid gate chatter on sparse events.

**Implication for first prediction:** Under default parameters with BG_TH_OPEN=2, the burst gate will not open until it has counted ≥2 events within the window. With a WINDOW of ~5 ms, the gate decision occurs at the first window boundary after accumulating 2+ correlated events. First prediction is gated by this delay.

**VEL_INIT invariant:** The predictor's cold-start velocity initialization (`VEL_INIT`) triggers on the first `bg_v` pulse after reset. With BG_TH_OPEN=2, the first `bg_v` corresponds to the second directional event, at which point `dir_x`/`dir_y` from the Reichardt accumulator reflect at least one directional correlation. Changing BG_TH_OPEN or reducing WINDOW below the time needed to accumulate 2 correlated events will break VEL_INIT timing.

#### Stage 5: ab_predictor / tracker_pool

**Single tracker (NTRACK=1):** The `ab_predictor` module operates in Q8.8 fixed-point (24-bit internal precision).

**State registers:**
- `x_q, y_q` [23:0]: Position in Q8.8 (bits [23:8] = integer pixels, [7:0] = sub-pixel fraction)
- `vx_q, vy_q` [23:0]: Velocity in Q8.8

**α-β update (on each valid non-outlier measurement):**
```
meas_x_q  = in_x << 8                         // to Q8.8
x_pred    = x_q + vx_q                        // prior state prediction
res_x     = meas_x_q - x_pred                 // residual (measurement - prediction)
x_q_new   = x_pred + (A_GAIN * res_x) >> 8    // A_GAIN = 192 = 0.75 in Q0.8
vx_q_new  = vx_q + (B_GAIN * res_x) >> 8 + (dir_vx >> 4)  // B_GAIN = 64 = 0.25
x_hat     = clamp(x_q_new >> 8, 0, 2^XW - 1)  // integer output, clamped
```

**Outlier rejection:** If `|res_x| > OUTLIER_TH << 8` (default OUTLIER_TH=128 pixels), the measurement is rejected. The predictor coasts using the prior prediction and decays velocity: `vx_q -= vx_q >> 4`. Output updates with the coasted position.

**Cold-start (initialized=0):** The first valid measurement bypasses outlier rejection and initializes state directly from the measurement. Velocity is set to ±VEL_INIT in the direction indicated by `dir_x`, or 0 if VEL_INIT=0. `initialized` is set to 1 after the first measurement.

**Characterised accuracy (diagnostics_full/12):**
- Steady state (after ~7 updates): 1–2 px error
- Cold-start lag (updates 1–7): up to 16 px (= 1 tile width at AW=8, XW=10)
- The ±2 px specification is met in steady state, not from the first measurement

**Multi-target pool (NTRACK > 1, tracker_pool.v):** When NTRACK > 1, `libellula_top` instantiates `tracker_pool` instead of `ab_predictor` directly. The pool contains NTRACK independent predictor instances.

Assignment logic (combinational, per `bg_v` pulse):
1. Compute L1 distance from measurement to each active tracker's cached position
2. If any active tracker is within ASSIGN_TH pixels: route to the closest one
3. Otherwise: spawn a new tracker from the idle pool, initialize from measurement
4. Increment coast counter for all unassigned active trackers
5. Retire (soft_rst) any tracker whose coast counter reaches COAST_TIMEOUT

**Validated:** NTRACK=4 in `tb_multi_target_pool.v` (2 targets on separate tracks, 0 px y-error each). Pool assignment is validated against the AXI backpressure bench (`tb_axi4s_pred_burst`, 33/33 assertions pass).

---

## 3. Interface Specifications

### 3.1 libellula_top — Core Pipeline

**Input ports:**

| Port | Width | Description |
|------|-------|-------------|
| `clk` | 1 | Rising-edge clock |
| `rst` | 1 | Active-high synchronous reset |
| `aer_req` | 1 | AER event request (level-sensitive) |
| `aer_x` | XW | Event X coordinate |
| `aer_y` | YW | Event Y coordinate |
| `aer_pol` | 1 | Event polarity (0=OFF, 1=ON) |
| `scan_addr` | AW | LIF scan address — must be a free-running counter, 0 to 2^AW-1 |

**Output ports:**

| Port | Width | Description |
|------|-------|-------------|
| `aer_ack` | 1 | AER acknowledge (combinational: `aer_req && !rst`) |
| `pred_valid` | 1 | Prediction output strobe |
| `x_hat` | PW | X prediction, Q8.8 fixed-point (bits [PW-1:8] = integer) |
| `y_hat` | PW | Y prediction, Q8.8 fixed-point |
| `conf` | 8 | Confidence score (0–255) |
| `conf_valid` | 1 | Confidence strobe |
| `track_id` | 2 | Tracker index (0 when NTRACK=1) |

**AER handshake timing:**
```
Cycle N:   aer_req=1, aer_x/y/pol valid
           aer_ack=1  (combinational, same cycle)
Cycle N+1: aer_req must be 0 OR next event already presented
```
The interface implements a 1-cycle acknowledge protocol. There is no wait state; the pipeline accepts one event per clock cycle if `aer_req` stays high. Sources that hold `aer_req` high for multiple cycles will generate one event per cycle, which is handled correctly (verified in `tb_aer_req_stuck_high.v`).

### 3.2 Parameters (libellula_top)

| Parameter | Default | Constraints |
|-----------|---------|-------------|
| `XW` | 10 | Sensor X bit width |
| `YW` | 10 | Sensor Y bit width |
| `AW` | 8 | LIF tile address width; scan period = 2^AW cycles; tile size = 2^((XW-AW/2)) × 2^((YW-(AW-AW/2))) pixels |
| `DW` | 0 | Delay lattice depth = 2^DW; 0 = single-event delay (recommended for sparse LIF spikes) |
| `PW` | 16 | Prediction output width; must accommodate Q8.8 representation of max coordinate |
| `NTRACK` | 1 | Tracker count; >1 instantiates tracker_pool |
| `ASSIGN_TH` | 96 | Tracker assignment L1-distance threshold (pixels) |
| `COAST_TIMEOUT` | 4 | Missed-update cycles before tracker retirement |
| `LIF_LEAK_SHIFT` | 4 | **Must be ≥ 4** (see §5.1) |
| `LIF_THRESH` | 16 | LIF spike threshold |
| `LIF_HIT_WEIGHT` | 1 | Charge per event |
| `BG_TH_OPEN` | 2 | Burst gate open threshold |
| `BG_TH_CLOSE` | 1 | Burst gate close threshold |
| `BG_WINDOW_OVR` | 0 | 0 = auto (1 << AW+12); positive integer = explicit window override |
| `VEL_INIT` | TILE_STEP_PX | Cold-start velocity (0 = disable) |
| `VEL_SAT` | TILE_STEP_PX×2 | Velocity saturation limit |

**Computed at elaboration time:**
```
TILE_STEP_PX = 1 << (XW - AW/2)     // tile side length in pixels
VEL_SAT      = TILE_STEP_PX * 2      // auto-scales with tile size
BURST_WINDOW = (BG_WINDOW_OVR > 0) ? BG_WINDOW_OVR : (1 << (AW + 12))
```

### 3.3 AXI4-Stream Interface

#### Input bridge: axi4s_to_aer

Converts an AXI4-Stream event beat to AER handshake. FSM: IDLE → S_REQ → IDLE (2 cycles per event).

**TDATA packing (32-bit, little-endian):**
```
[31:21]  reserved
[20]     pol
[19:10]  y[9:0]
[ 9: 0]  x[9:0]
```

Peak throughput: 1 event per 2 clocks = 100 Meps at 200 MHz. Validated at 1 Meps in `tb_aer_throughput_1meps.v`.

#### Output bridge: axi4s_pred_wrapper

Converts `pred_valid` strobes to an AXI4-Stream master. Includes a depth-4 FIFO for backpressure absorption with fast-path bypass when FIFO empty and output idle.

**TDATA packing (48-bit):**
```
[47:40]  8'b0     reserved
[39:32]  conf[7:0]
[31:16]  y_hat[15:0]   Q8.8
[15: 0]  x_hat[15:0]   Q8.8
```
`TKEEP = 6'b111111`, `TLAST = TVALID` (single-beat transaction per prediction).

**FIFO overflow:** If the FIFO fills and downstream holds TREADY=0, additional predictions are dropped (simulation warning emitted under `-DSIMULATION`). With NTRACK=4 and FIFO_DEPTH=4, up to 4 simultaneous tracker firings are absorbed without loss.

#### SoC wrapper: libellula_soc

Full integration: AXI4-S input + output, internal scan counter, active-low reset. Output TDATA is 64 bits to carry `track_id`.

**TDATA packing (64-bit):**
```
[63:48]  16'b0
[47:46]  track_id[1:0]
[45:40]  6'b0
[39:32]  conf[7:0]
[31:16]  y_hat[15:0]
[15: 0]  x_hat[15:0]
```
`TKEEP = 8'hFF`, `TLAST = TVALID`.

Reset convention: `libellula_top` uses active-high `rst`; AXI bridges use active-low `rst_n`; `libellula_soc` handles the inversion internally.

---

## 4. Timing Model

### 4.1 Pipeline Propagation

End-to-end latency from `aer_req` to `pred_valid`: **5 clock cycles**, measured in `tb/tb_latency.v` with burst gate configured as pass-through (COUNT_TH=0).

This measurement is under ideal conditions. The burst gate is bypassed; the LIF receives a pre-aligned event on a pre-charged neuron. This gives the minimum achievable latency for a cold-start-free, gate-open condition.

### 4.2 Accumulation Time (LIF)

**Scan period:** 2^AW cycles. With AW=8 at 200 MHz: 256 cycles = 1.28 μs.

**Minimum dwell per tile to guarantee spiking:**
```
dwell_cycles ≥ THRESH × SCAN_PERIOD = 16 × 256 = 4096 cycles = 20.5 μs at 200 MHz
```
This is derived from the LIF fixed-point analysis. A target moving faster than one tile per 4096 cycles will not accumulate enough membrane potential to spike. Maximum trackable angular velocity:
```
tile_width_px / dwell_cycles = 64 px / 4096 cycles = 3.1 Mpx/s at 200 MHz
```
For a DVS sensor with 240×180 resolution, the full-width traversal at this rate takes ~77 μs. Practical tracking scenarios (lab-scale prey at <500 px/s) are well within this limit.

### 4.3 Cold-Start Convergence

The predictor requires approximately 7 measurement updates to converge to ±2 px steady state after initialization. During warmup:

| Update # | Typical x-error |
|----------|-----------------|
| 1 | 0 px (initialized from measurement) |
| 2–3 | 16 px (velocity not yet established) |
| 4 | 12 px |
| 5 | 8 px |
| 6 | 5 px |
| 7 | 3 px |
| 8+ | 1–2 px (steady state) |

Source: `diagnostics_full/12_CHARACTERISATION.md`.

Each "update" corresponds to one LIF spike from the target tile reaching the predictor. At 2 spikes/scan-period, 7 updates ≈ 3.5 scan periods ≈ 896 cycles ≈ 4.5 μs at 200 MHz.

### 4.4 Clock and Reset

**Single clock domain.** No CDC paths. No gated clocks. No asynchronous reset.

**Reset duration:** `rst=1` must be held for at least 2^AW consecutive cycles to guarantee full state_mem clearance. For AW=8: 256 cycles minimum. Verified in `tb_formal_props.v` property P3.

**Output behavior during reset:** `pred_valid` and `conf_valid` are gated with `!rst`. Verified in `tb_reset_midstream_top.v` (266-cycle mid-stream reset, zero valid leaks observed).

---

## 5. Design Constraints and Limits

### 5.1 LEAK_SHIFT Must Be ≥ 4

The LIF fixed-point equation is: `state_fp = HIT_RATE_PER_SCAN × SCAN_PERIOD × (1 - retention)^(-1)`, where `retention = (2^LEAK_SHIFT - 1) / 2^LEAK_SHIFT`.

With LEAK_SHIFT=2 (retention=0.75): `state_fp = 4`. Since 4 < THRESH=16, the LIF never spikes at any stimulus rate. This is not a corner case; it is a mathematical fixed point that holds regardless of event density.

With LEAK_SHIFT=4 (retention=0.9375): `state_fp = 16` at 1 event/scan — exactly at threshold. Safe operation requires ≥ 2 events/scan, which gives `state_fp = 32 > 16`.

**Constraint:** `LIF_LEAK_SHIFT ≥ 4` for any configuration with default THRESH=16 and HIT_WEIGHT=1. This constraint changes if THRESH or HIT_WEIGHT are modified. The mathematical check is: `state_fp > THRESH`, where `state_fp = HIT_WEIGHT × HIT_RATE_PER_SCAN × SCAN_PERIOD × 2^LEAK_SHIFT`.

### 5.2 Spatial Hash — No Alternatives

The delay lattice uses STEP=1 neighbor comparison in tile-index space. The tile hash must map spatially adjacent pixels to adjacent indices. Only the spatial hash `{x[XW-1:XW-HX], y[YW-1:YW-HY]}` satisfies this. An XOR hash randomizes adjacency and produces zero directional correlation. There is no runtime check for this; using a non-spatial hash produces a silently broken design.

### 5.3 DW=0 for Standard Operation

With DW=6 (64-event buffer), the delay lattice requires 65 LIF spikes before any direction correlation can fire (the ring buffer must be full before a tail-position event can be compared against a head-position event). For a target crossing 10 tiles (10 spikes), DW=6 produces zero directional output. DW=0 (1-event buffer) compares each spike against the immediately preceding spike — the correct behavior for tile-based LIF where consecutive spikes represent directional motion.

DW > 0 is appropriate only when LIF produces a very high spike rate and temporal integration across many spikes is desired.

### 5.4 Single-Target Limitation (NTRACK=1)

A single `ab_predictor` locks to one target. With two targets separated by more than OUTLIER_TH pixels (default 128 px), the predictor initializes on the first target seen and permanently rejects measurements from the other as outliers. This was measured explicitly: two targets at y=400 and y=656 (256 px separation > 128 px threshold) — predictor locked to one, rejected the other with mean error 256 px (diagnostics_full/12, §Multi-Target).

NTRACK > 1 (tracker_pool) is provided to address this. Validated in simulation at NTRACK=4 (tb_multi_target_pool, tb_axi4s_pred_burst).

### 5.5 Outlier Threshold vs. Target Separation

OUTLIER_TH=128 px applies to individual measurement residuals (prediction error). Any measurement farther than 128 px from the current prediction is rejected. This means:
- Two simultaneous targets separated by > 128 px: second target permanently rejected by a single predictor instance
- A fast-moving target with velocity > 128 px/update: every measurement rejected after the predictor falls behind
- A tracker that has coasted significantly: may reject its own target on reacquisition

With NTRACK > 1, each tracker has its own OUTLIER_TH, applied to its own local prediction. The pool assignment step (L1 distance routing) handles the separation correctly before passing to individual predictors.

### 5.6 Memory Initialization for ASIC

`lif_tile_tmux` and `delay_lattice_rb` use `initial` blocks to zero-initialize register arrays (`state_mem`, ring buffer). FPGA tools handle this correctly. Standard-cell ASIC synthesis may strip `initial` blocks depending on tool configuration. ASIC integration requires explicit memory initialization strategy (scan-based initialization or power-on reset long enough to cycle through all addresses).

### 5.7 Scan Address Contract

`scan_addr[AW-1:0]` must be a free-running counter cycling through 0 to 2^AW-1. The LIF state machine uses `scan_addr` to determine which neuron to update each cycle. If `scan_addr` is held static or driven non-sequentially, the LIF will repeatedly update one neuron and never update others, producing incorrect behavior. `libellula_soc` handles this internally. Bare `libellula_top` instantiations must drive it externally.

---

## 6. Test Suite

### 6.1 Organization

```
tb/              Core functional testbenches (34 distinct benches executed by make test)
tb_hostile/      Failure-mode and stress testbenches (3 benches)
tb/tb_formal_props.v    Bounded formal simulation (50,000 cycles)
tb/tb_golden_gen.v      Golden vector generator
tb/tb_replay_lockstep.v Bit-exact replay verification
tb/tb_coverage_full.v   VCD dump for toggle coverage analysis
```

### 6.2 Core Bench Results

`make test` (the primary CI target) runs:

| Category | Count | Result |
|----------|-------|--------|
| Claim metric benches (latency, px300, meps) — each run 3 times | 3 × 3 | PASS |
| Unit tests (aer_rx, lif, delay_lattice, reichardt, burst_gate, ab_predictor, conf_gate, lif_liveness) | 8 | PASS |
| Scenario tests (cv_linear, clutter, crossing, reversal, multi_target, idle, etc.) | 20 | PASS |
| Hostile tests (mid-stream reset, stuck-REQ, random stress) | 3 | PASS |
| **`make test` total (distinct benches)** | **34** | **ALL PASS** |

`make run-once` additionally runs power and diagnostic suites:

| Extra in `run-once` | Count | Notes |
|---------------------|-------|-------|
| Power benches (tb_power_lo, tb_power_hi) | 2 | VCD toggle counts, ratio ≥ 1.3× asserted |
| Diagnostic benches (tb_ingestion_liveness, tb_canonical_motion_audit) | 2 | Compiled with `-DLIBELLULA_DIAG` |
| **`make run-once` total (distinct benches)** | **38** | **ALL PASS** |

| AXI4-S layer (make axi) | 4 benches, 111 assertions | ALL PASS |

### 6.3 How PASS/FAIL Is Determined

Every assertion-based bench produces `PASS` or `FAIL: <description>` via `$display`, followed by `$finish`. The Makefile parses this output; any bench that does not produce `PASS` on its final line is treated as a failure. Three power measurement benches (`tb_power_lo`, `tb_power_hi`) and one debug bench produce VCD only with no automated assertion — their output is not included in the PASS count.

### 6.4 Key Claim Bench Details

**tb_latency.v:**  
Drives a single event, measures cycle count from `aer_req` assertion to `pred_valid` assertion. Burst gate set to pass-through (COUNT_TH=0). Asserts LATENCY_CYCLES ≤ 6. Result: 5 cycles.  
*Caveat:* Burst gate bypass means this is the minimum achievable latency. Normal operation with burst gate enabled delays first prediction until gate-open conditions are met.

**tb_px_bound_300hz.v:**  
Constant-velocity linear motion at 300 Hz event rate (667 clock cycles between events at 200 MHz). Checks per-sample prediction error for each `pred_valid` output; asserts no sample exceeds ±2 px. Tests X-axis motion only.  
*Caveat:* Per-sample, not RMS. Steady-state only (cold-start warmup period not assessed separately here). LIF and burst_gate parameters overridden to ensure consistent throughput.

**tb_aer_throughput_1meps.v:**  
Injects 2000 events at 1 Meps spacing. Counts `aer_ack` responses; asserts ACK==REQ. Result: REQ=2000, ACK=2000, PRED=7. Zero dropped events.  
*Caveat:* Validates AER handshake integrity, not downstream processing rate. PRED=7 shows burst gate filtered most events. Event spacing is uniform (not burst); sustained burst behavior at 1 Meps not tested.

**tb_formal_props.v (make formal):**  
Bounded simulation, 50,000 cycles, LFSR seed 0xDEADBEEF. Two identically-driven DUT instances. Five properties:
- P1: `pred_valid` and `conf_valid` = 0 during reset
- P2: No X/Z on `pred_valid`, `conf_valid`, `aer_ack` at any cycle
- P3: All 2^AW state_mem cells = 0 exactly 2^AW+5 cycles after reset assertion
- P4: Upper bits of `x_hat`/`y_hat` zero on every `pred_valid`
- P5: Bit-exact output match between DUT A and DUT B  

This is bounded simulation, not unbounded model checking (no SymbiYosys/Yosys in this toolchain). P1–P5 hold for all states observed over 50,000 cycles.

**tb_reset_midstream_top.v (make test_reset):**  
Phase 1: injects 80 events, drains 40 cycles, captures all `pred_valid` outputs. Asserts `rst=1` for 266 cycles mid-stream. Phase 2: identical stimulus repeated. Compares phase-1 and phase-2 outputs sample-by-sample for bit-exact determinism. Monitors every posedge for valid leaks during reset.  
Parameters: DW=0, LIF_THRESH=4. Captures up to 16 predictions per phase.

**tb_random_stress_top.v:**  
50,000 random events (LFSR-generated x, y, pol). Checks no X/Z on outputs, no stuck-valid conditions. Pipeline remains live throughout.

**tb_coverage_full.v / make coverage_report:**  
VCD dump over 7 scenarios (linear motion, polarity complement, mid-stream reset, post-reset stimulus, target+clutter interleaved, dense same-pixel burst, idle period). Python script `tools/coverage_report.py` parses VCD and reports per-module toggle coverage. Pass threshold: 70%. Achieved: 72%. FSM-like booleans (`initialized`, `gate_state`, `out_valid_int`) all toggled.

**tb_replay_lockstep.v / make replay_lockstep:**  
`make golden_vectors` runs `tb_golden_gen.v` (80 events, constant velocity) and writes `build/golden/expected.txt` (one hex line per `pred_valid`). `make replay_lockstep` replays the identical 80-event stimulus and compares every `pred_valid` output against the frozen expected file. Result: 18/18 hex-exact. Provides a regression gate for RTL changes.

### 6.5 Characterised Scenarios (diagnostics_full/12)

Beyond the automated test suite, the full-pipeline characterisation bench measured:

| Scenario | Result |
|----------|--------|
| Single-target constant-velocity East, 6 tiles | Steady-state: 1–2 px error. Cold-start: 16 px (7 updates to converge) |
| Velocity range (3000–16000 cycle dwell) | All tracked. Hard floor: 4096 cycles/tile (20.5 μs at 200 MHz) |
| Clutter injection (up to 1 event per 64 cycles) | Performance unaffected at all tested clutter rates |
| Direction reversal (East → West) | Relock within 2 tile transitions. Peak overshoot: 26 px, converging to 1 px |
| Multi-target (2 targets, 256 px separation, NTRACK=1) | Predictor locked to one; rejected other (residual > OUTLIER_TH). This is expected behavior for NTRACK=1 |

---

## 7. Validation Evidence — Honest Summary

The table below states what is validated, what is not, and the evidence scope.

| Claim | Evidence | Scope | Notes |
|-------|----------|-------|-------|
| 5-cycle pipeline latency | tb_latency, raw log | Burst gate bypassed | Minimum achievable. Normal operation has longer time-to-first-prediction |
| ±2 px steady-state accuracy under constant velocity | tb_px_bound_300hz, characterisation bench | X-axis linear, constant velocity, post-warmup only | Cold-start lag up to 16 px for first 7 updates |
| 1 Meps, zero event drops | tb_aer_throughput_1meps, tb_meps_nodrop | AER handshake integrity | Uniform event spacing; burst behavior not tested |
| Prediction suppressed during reset | tb_reset_midstream_top, tb_formal_props P1 | DW=0, THRESH=4 bench params | |
| Deterministic re-entry after reset | tb_reset_midstream_top, tb_replay_lockstep | Same bench params | Bit-exact phase 1/phase 2 comparison |
| state_mem cleared after reset | tb_formal_props P3 | Bounded: holds for 50K cycles | Not unbounded proof |
| No X/Z on outputs | tb_formal_props P2 | Bounded: 50K cycle LFSR | Not unbounded proof |
| Clutter rejection (MAE ≤ baseline) | tb_cross_clutter, characterisation bench | Up to 1.6 noise events/scan tested | Rejection limit not characterized |
| Tracker pool (NTRACK=4) | tb_multi_target_pool, tb_axi4s_pred_burst | Simulation only | Not characterized under mixed-velocity multi-target |
| AXI4-S protocol compliance | tb_axi4s_pred_burst (ARM IHI 0051A case 5) | Simulation | No formal AXI compliance test tool |
| Toggle coverage 72% | coverage_report.py on VCD | 7 scenarios, iverilog | Not functional coverage or branch coverage |
| Lint-clean | Verilator 5.038 -Wall | After suppression policy applied | PROCASSINIT suppressed globally; WIDTHTRUNC inline; WIDTHEXPAND fixed structurally |
| Activity-proportional switching | tb_power_lo / tb_power_hi VCD toggle counts | Measurement only | **No automated assertion.** Ratio not enforced programmatically |
| Velocity tracking up to 3.1 Mpx/s | Derived from characterisation + timing model | Mathematical bound | Not directly measured with a fast target bench |
| UAV parameter profile | Application tuning rationale | None | **Not simulation-validated against a UAV scenario** |
| Synthesis-ready RTL | Vendor-neutral Verilog-2001, Verilator lint | | **Not synthesis-tested against any FPGA or cell library** |

---

## 8. Integration Guidance

### 8.1 Minimum Viable Integration (FPGA)

```verilog
// External requirements:
//   - clk:       ≤ 200 MHz (no timing closure verified)
//   - rst:       active-high, hold for ≥ 2^AW = 256 cycles
//   - scan_addr: free-running AW-bit counter, driven from same clk domain

reg [AW-1:0] scan_ctr = 0;
always @(posedge clk) scan_ctr <= scan_ctr + 1;

libellula_top #(
    .XW(10), .YW(10), .AW(8), .DW(0), .PW(16),
    .LIF_LEAK_SHIFT(4),   // must be >= 4
    .LIF_THRESH(16),
    .LIF_HIT_WEIGHT(1),
    .BG_TH_OPEN(2),
    .BG_TH_CLOSE(1),
    .NTRACK(1)
) u_libellula (
    .clk(clk), .rst(rst),
    .aer_req(aer_req),   .aer_ack(aer_ack),
    .aer_x(aer_x),       .aer_y(aer_y),       .aer_pol(aer_pol),
    .scan_addr(scan_ctr),
    .pred_valid(pred_valid),
    .x_hat(x_hat),       .y_hat(y_hat),
    .conf(conf),         .conf_valid(conf_valid),
    .track_id()          // tie off if NTRACK=1
);
```

### 8.2 Sensor Interface

LIBELLULA expects level-sensitive AER: `aer_req` high = event present, `aer_ack` = accepted, source must lower `aer_req` next cycle. This matches the AER protocol used by most DVS sensors in parallel-bus mode.

For USB-based sensors (Inivation DAVIS, Prophesee Metavision) delivering events via host software, events must be re-packetized into level-sensitive AER before entering the pipeline. The included `axi4s_to_aer` bridge covers the case where event packets arrive via AXI4-S.

For direct FPGA connection to sensors with serialized AER output, a deserialization layer is needed upstream of `aer_rx`. This layer is not included.

### 8.3 Event Rate Requirements

To produce predictions, the pipeline requires:
1. Enough events per tile to spike the LIF: ≥ 2 events per 256-cycle scan period at default parameters
2. Enough spikes in adjacent tiles to trigger the Reichardt correlator (at least 2 consecutive spikes in neighboring tiles within the DW=0 one-event window)
3. Enough correlated events to open the burst gate: BG_TH_OPEN=2 events within the WINDOW

For a target moving at 1 event/tile/scan (minimum), first prediction time is approximately:
```
first_pred_time ≈ BURST_WINDOW cycles = 2^(AW+12) cycles = 1,048,576 cycles = 5.2 ms at 200 MHz
```
This is the window during which events accumulate before the burst gate makes its first open decision. In practice, pre-loading an open gate (`BG_TH_OPEN=1`, `BG_WINDOW_OVR=4`) dramatically reduces time-to-first-prediction for known-active scenes.

### 8.4 Output Interpretation

`x_hat` and `y_hat` are PW-bit unsigned values in Q8.8 format. Integer pixel coordinate = `x_hat >> 8`. Sub-pixel fraction = `x_hat[7:0]`. The upper bits (`x_hat[PW-1:XW+8]`) should be zero when `pred_valid` fires; this is verified by property P4.

`conf` is a heuristic combination of event count and direction magnitude: `conf = min(255, ev_cnt*8 + vmag)`. It is not a calibrated probability. Higher values indicate higher recent event density and stronger directional signal.

`track_id` is meaningful only when NTRACK > 1. With NTRACK=1 it is always 0.

### 8.5 Evaluation Package

`make package_eval` assembles:
```
build/eval_package/
├── README_eval.md          Entry point
├── interface_spec.md       Port list, TDATA packing
├── latency_spec.md         Latency measurement methodology
├── verified_claims.md      Claims with bench citations
├── known_limits.md         Constraints from this document
├── req_trace.md            23-requirement traceability table
├── toolchain_manifest.txt  Simulator versions + RTL SHA-256
└── SHA256SUMS.txt          Package checksum manifest
```

`make req_trace` generates `build/req_trace.md` mapping all 23 requirements (REQ-01 through REQ-23) to bench files and make targets.

---

## 9. Known Limitations (Unresolved as of v22)

1. **Power bench has no automated assertion.** `tb_power_lo` and `tb_power_hi` produce VCD and print toggle counts but do not assert a minimum ratio. Activity-proportional switching is a structural property of the architecture, not an automatically checked simulation result.

2. **Cold-start ±2 px spec applies steady-state only.** The first 7 predictions after initialization carry up to 16 px error. Applications with latency constraints shorter than 7 update periods (at minimum dwell rate: ~7 × 4096 = 28,672 cycles ≈ 143 μs at 200 MHz) will observe cold-start errors.

3. **Clutter rejection limit not characterized.** Tested up to 1 event per 64 cycles (1.6× signal rate per scan). The SNR boundary at which false positives begin is not known.

4. **Direction reversal overshoot: 26 px peak.** After a target reversal, the predictor carries residual velocity from the previous direction. Peak overshoot measured at 26 px, decaying to 3 px within 3 tile transitions. Applications with tight error bounds during maneuvers should account for this.

5. **Formal verification is bounded simulation, not model checking.** Properties P1–P5 hold over 50,000 cycles with an LFSR stimulus. Unbounded proofs (via SymbiYosys or equivalent) have not been run. The toolchain does not include yosys/sby.

6. **No FPGA synthesis results.** Timing closure, resource utilization (LUT/FF/BRAM counts), and maximum achievable frequency are not characterized against any target device. The design uses Verilog-2001 constructs compatible with standard synthesis flows, but this has not been verified by running synthesis.

7. **No silicon-level validation.** All performance figures are derived from RTL simulation. No FPGA bitstream has been generated or tested against a physical event camera.

8. **ASIC `initial` block concern.** `state_mem` in `lif_tile_tmux` and the ring buffer in `delay_lattice_rb` use `initial` blocks for simulation-time zeroing. ASIC synthesis tools may strip these. ASIC integration requires explicit reset initialization strategy.

9. **UAV parameter profile is untested.** The parameter set documented in the README for 10–25 m/s intercept scenarios (LEAK_SHIFT=14, THRESH=4, HIT_WEIGHT=8192, BG_TH_OPEN=1, etc.) is a tuning rationale, not a validated configuration. No bench exists that simulates a UAV-scale target against a UAV-scale DVS event rate.

10. **Tracker pool maximum target count not characterized.** NTRACK=4 is tested with 2 targets on separate tracks. Behavior at 3 or 4 simultaneous targets, mixed-velocity targets, or targets that cross ASSIGN_TH boundaries has not been characterized.

---

## 10. Diagnostic Infrastructure

The repository includes a full diagnostic suite produced during the LEAK_SHIFT=2 root-cause investigation (`diagnostics_full/`). These records contain:

- `00_EXEC_SUMMARY.md`: One-sentence verdict, phase-by-phase status, critical evidence
- `01` through `10`: Step-by-step root cause isolation (LIF unit analysis, hash contract, stage activity trace, parameter sweep, gate analysis)
- `11_REPAIR_AND_VALIDATION.md`: Complete repair log with before/after bench results
- `12_CHARACTERISATION.md`: Full quantitative pipeline characterisation (accuracy, velocity range, clutter, reversal, multi-target)
- `out/`: Machine-readable CSV outputs from all diagnostic scripts
- `scripts/`: Python diagnostic runners (`run_full_diagnostic.py` re-runs the full diagnostic sequence)

These records are the primary evidence that the pipeline functions correctly and the basis for the quantitative limits stated in this document.

---

## 11. Repository Quick Reference

```
rtl/                  All synthesizable RTL (12 modules)
tb/                   Core testbenches
tb_hostile/           Failure-mode testbenches
sim/Makefile          All build targets
tools/                coverage_report.py, req_trace.py
diagnostics_full/     Root cause and repair records (00_EXEC_SUMMARY → 13_P1_P2_P3_RESULTS)
doc/                  CLAIMS, AXI integration, traceability
```

**Recommended verification sequence:**
```bash
cd sim
make test               # 34 distinct benches, all must pass
make axi                # 111 assertions, all must pass
make lint               # zero Verilator warnings
make formal             # 5 bounded properties, 50K cycles
make golden_vectors     # freeze reference vectors
make replay_lockstep    # confirm bit-exact replay
make coverage_report    # toggle coverage ≥ 70%
make req_trace          # 23-requirement traceability table
make package_eval       # assemble evaluation package
```
