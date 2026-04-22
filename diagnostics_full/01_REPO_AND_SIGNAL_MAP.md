# Repository and Signal Map

Generated: independent verification run, 2026-04-11.

---

## 1. Module Hierarchy

```
libellula_top (rtl/libellula_top.v)
  ├── aer_rx           (rtl/aer_rx.v)
  ├── lif_tile_tmux    (rtl/lif_tile_tmux.v)    ← EARLIEST DEAD STAGE
  ├── delay_lattice_rb (rtl/delay_lattice_rb.v)
  ├── reichardt_ds     (rtl/reichardt_ds.v)
  ├── burst_gate       (rtl/burst_gate.v)
  ├── ab_predictor     (rtl/ab_predictor.v)      ← pred_valid source
  └── conf_gate        (rtl/conf_gate.v)

Wrappers (not part of evaluator-facing predictive path):
  axi4s_pred_wrapper   (rtl/axi4s_pred_wrapper.v)
  axi4s_to_aer         (rtl/axi4s_to_aer.v)
```

The evaluator-facing predictive path top module is **`libellula_top`**.

---

## 2. Pipeline Timing (from comments in libellula_top.v)

| Stage     | Δ cycles | Signal(s)           | Description                   |
|-----------|----------|---------------------|-------------------------------|
| AER RX    | +0       | ev_v, ev_x, ev_y    | Event from AER bus            |
| LIF       | +2       | lif_v, lif_x, lif_y | Spike (2-stage pipeline)      |
| Delay     | +3       | v_e…v_sw, x_tap     | Correlation taps (registered) |
| Reichardt | +4       | ds_v, dir_x, dir_y  | Direction (lif_v_d1 delayed)  |
| Burst     | +5       | bg_v                | Gated valid                   |
| Predictor | +6       | pred_valid, x_hat   | Prediction output             |

---

## 3. Port List — libellula_top

| Direction | Name          | Width   | Description                               |
|-----------|---------------|---------|-------------------------------------------|
| input     | clk           | 1       | System clock                              |
| input     | rst           | 1       | Synchronous active-high reset             |
| input     | aer_req       | 1       | AER level request                         |
| output    | aer_ack       | 1       | AER acknowledge                           |
| input     | aer_x         | XW=10   | Event X coordinate                        |
| input     | aer_y         | YW=10   | Event Y coordinate                        |
| input     | aer_pol       | 1       | Event polarity                            |
| **input** | **scan_addr** | **AW=8**| **External LIF scan — no default driver** |
| output    | pred_valid    | 1       | Prediction valid pulse                    |
| output    | x_hat         | PW=16   | Predicted X (Q8.8)                        |
| output    | y_hat         | PW=16   | Predicted Y (Q8.8)                        |
| output    | conf          | 8       | Confidence score                          |
| output    | conf_valid    | 1       | Confidence valid                          |

---

## 4. pred_valid — Exact Source Locations

**`rtl/ab_predictor.v` lines 43–44:**
```verilog
reg out_valid_int = 1'b0;
assign out_valid = out_valid_int && !rst;
```

**Condition for pred_valid to assert:** `bg_v` must be 1, `in_valid` must be 1 at `ab_predictor`.

**`rtl/libellula_top.v` line 175:**
```verilog
ab_predictor u_ab (.in_valid(bg_v), ..., .out_valid(pred_valid), ...);
```

Full upstream chain:
```
ev_v → lif_v → [delay_lattice_rb] → lif_v_d1 → [reichardt_ds] → ds_v
     → [burst_gate] → bg_v → ab_predictor → pred_valid
```

---

## 5. scan_addr — Exact Source Locations

**`rtl/libellula_top.v` line 35:** Input port — no internal driver in RTL.
**`rtl/lif_tile_tmux.v` lines 26, 105:**
```verilog
input wire [AW-1:0] scan_addr,   // port
...
scan_addr_s1 <= scan_addr;       // registered into Stage 0
```

All testbenches provide scan_addr via: `always @(posedge clk) if (!rst) scan <= scan + 1'b1;`
This cycles 0→255 (AW=8) with no synchronization to events.

---

## 6. Hash / Address-Match Logic — Exact Source

**`rtl/lif_tile_tmux.v` lines 39–45:**
```verilog
localparam [AW-1:0] ADDR_MASK = {AW{1'b1}};
// Event-to-address hash (toy mapping): (x ^ y) mod 2^AW
wire [AW-1:0] hashed_xy = (in_x[AW-1:0] ^ in_y[AW-1:0]) & ADDR_MASK;
wire hit_comb = in_valid && (hashed_xy == scan_addr);
```

An event at (x, y) accumulates in the LIF ONLY in the one clock cycle where
`scan_addr == (x[AW-1:0] ^ y[AW-1:0])`.

With AW=8 and free-running scan, each address is open for 1 cycle per 256 cycles (0.39% duty cycle).

---

## 7. Default Parameters Affecting Spiking

| Parameter   | Module          | Default | Effect                                  |
|-------------|-----------------|---------|------------------------------------------|
| LEAK_SHIFT  | lif_tile_tmux   | **2**   | Leak = state >> 2 each scan cycle        |
| THRESH      | lif_tile_tmux   | **16**  | Spike threshold                          |
| AW          | libellula_top   | **8**   | 256 LIF addresses; scan period = 256     |
| SW          | lif_tile_tmux   | 14      | State width (not constraining)           |
| TH_OPEN     | burst_gate      | 3       | Events/window to open burst gate         |
| OUTLIER_TH  | ab_predictor    | 128     | Outlier rejection distance (pixels)      |

**Critical finding (mathematically proven, simulation-confirmed):**

With `LEAK_SHIFT=2`, `THRESH=16`: st_next = st − (st>>2) + hit.
Fixed point with continuous hits (hit=1 every cycle, scan held): st*=4 (since 4>>2=1, net=0).
Starting from st=0: 0→1→2→3→4 then stable. **4 < 16 = THRESH. Never spikes.**

Simulation confirmation (iverilog, this run):
```
LIF_RESULT bench=hold_default mode=0 target=5 hit_count=64 hit_spacing=0
          peak=4 spiked=0 first_spike=-1 final_state=3 leak_shift=2 thresh=16
```

---

## 8. Hidden Assumptions

1. **scan_addr requires an external driver.** The README does not document this. No internal generator exists. All benches use free-running counter.

2. **Hit acceptance is for one clock cycle only.** No buffering, retry, or hold mechanism. Event is silently dropped if hash doesn't match scan at the presentation cycle.

3. **LIF comment says "toy mapping"** (lif_tile_tmux.v:41). The XOR hash is explicitly labeled provisional.

4. **libellula_top.AW=8 but XW=YW=10** — 256 neurons covering 1M-pixel space. Average of 4096 pixels share each neuron, causing heavy aliasing.

5. **LIBELLULA_STAGE_DIAG** is the diagnostic define used in libellula_top.v (lines 188–256). Must be set at compile time with `-DLIBELLULA_STAGE_DIAG`.
