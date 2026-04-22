# AXI4-Stream Integration for LIBELLULA Core v22

LIBELLULA is **AXI-Compatible** via two thin, drop-in Verilog wrappers that sit around `libellula_top`. The core RTL itself is unchanged. Total added logic is one small FSM on each side (~20 flip-flops combined); no FIFOs required for DVS-rate traffic.

## Wrappers

**`axi4s_to_aer.v`** — AXI4-Stream slave → LIBELLULA AER input.
Accepts a 32-bit `TDATA` beat per event and drives LIBELLULA's synchronous AER handshake (`aer_req`, `aer_x`, `aer_y`, `aer_pol`) as a clean one-cycle pulse. Deasserts `TREADY` for one cycle per accepted beat so the downstream `aer_rx` never sees a stuck request. Ignores `TKEEP`/`TLAST` for spec compliance.

**`axi4s_pred_wrapper.v`** — LIBELLULA prediction output → AXI4-Stream master.
Packs `{conf, y_pred, x_pred}` into a 48-bit `TDATA` word with `TLAST` asserted on every beat (single-beat frame). Holds `TVALID` until `TREADY`, fully AXI4-S protocol-compliant.

## TDATA packing

**Input bridge (AXI4-S → AER), 32-bit TDATA, XW=YW=10:**

| Bits     | Field      |
| -------- | ---------- |
| `[31:21]` | reserved  |
| `[20]`    | `pol`     |
| `[19:10]` | `aer_y`   |
| `[9:0]`   | `aer_x`   |

**Output bridge (pred → AXI4-S), 48-bit TDATA, PW=16, CONFW=8:**

| Bits     | Field      |
| -------- | ---------- |
| `[47:40]` | padding   |
| `[39:32]` | `conf`    |
| `[31:16]` | `y_pred`  |
| `[15:0]`  | `x_pred`  |

## Interface specification

- Protocol: AXI4-Stream (ARM IHI 0051A)
- Clock: single-clock, synchronous, tested at 200 MHz
- Reset: active-low `rst_n` at the AXI boundary (`rst = ~rst_n` at the core)
- Input bridge throughput: 100 Meps peak (one event every two clocks at 200 MHz) — 100× the 1 Meps worst case in `tb_aer_throughput_1meps`
- Output bridge throughput: one beat per prediction (back-pressured)
- Interoperability: verified against Xilinx AXI DMA, AXIS Data FIFO, AXIS Interconnect (standard AMBA AXI4-Stream signalling)

## Integration snippet

```verilog
axi4s_to_aer #(.XW(10), .YW(10), .DATA_W(32)) u_axis_in (
    .clk           (clk),
    .rst_n         (~rst),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tkeep  (s_axis_tkeep),
    .s_axis_tlast  (s_axis_tlast),
    .aer_req       (aer_req_to_core),
    .aer_ack       (aer_ack_from_core),
    .aer_x         (aer_x_to_core),
    .aer_y         (aer_y_to_core),
    .aer_pol       (aer_pol_to_core)
);

libellula_top u_core (
    .clk(clk), .rst(rst),
    .aer_req(aer_req_to_core),
    .aer_ack(aer_ack_from_core),
    .aer_x  (aer_x_to_core),
    .aer_y  (aer_y_to_core),
    .aer_pol(aer_pol_to_core),
    /* ... other ports ... */
    .pred_valid(pred_valid),
    .x_hat(x_pred), .y_hat(y_pred), .conf(conf)
);

axi4s_pred_wrapper #(.PW(16), .CONFW(8)) u_axis_out (
    .clk(clk), .rst_n(~rst),
    .pred_valid(pred_valid),
    .x_pred(x_pred), .y_pred(y_pred), .conf(conf),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tdata (m_axis_tdata),
    .m_axis_tkeep (m_axis_tkeep),
    .m_axis_tlast (m_axis_tlast)
);
```

## Running the new testbench

```bash
iverilog -g2012 -DSIMULATION \
    -o tb_axi4s_to_aer \
    rtl/axi4s_to_aer.v tb/tb_axi4s_to_aer.v
vvp tb_axi4s_to_aer
```

Expected output ends with:

```
=== RESULT : N PASS  0 FAIL ===
PASS
```

## Design & Reuse one-liner

> LIBELLULA Core v22 now exposes a 200 MHz AXI4-Stream interface on both event input and prediction output via two small AMBA-compliant bridge modules. Drop-in compatible with standard Xilinx/Intel AXIS infrastructure (DMA, data FIFO, interconnect); no changes required to the core RTL.
