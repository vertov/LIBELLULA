# Phase 2 — LIF Tile Unit Analysis

Bench: `tb/tb_lif_unit_diag.v` drives a single `lif_tile_tmux` with deterministic hits on one hashed address, sampling `state_mem[target]` each cycle.

**Independent verification 2026-04-11.** All simulations re-run directly with iverilog 12.0 / vvp.

---

## Key Commands

```bash
# Default parameters (LEAK_SHIFT=2, THRESH=16), scan held, 64 hits
vvp sim/build/tb_lif_unit_diag +BENCH_NAME=hold_default \
  +TARGET_ADDR=5 +HIT_COUNT=64 +HIT_SPACING=0 +SCAN_MODE=0

# Sweep LEAK_SHIFT 0-5, THRESH=16
iverilog -g2012 -P tb_lif_unit_diag.P_LEAK_SHIFT=4 -P tb_lif_unit_diag.P_THRESH=16 \
  ... && vvp /tmp/lif_ls4 +HIT_COUNT=200 +SCAN_MODE=0
```

---

## Full Sweep Results (independently verified this run)

| LEAK_SHIFT | THRESH | Scan Mode | Hits | Peak State | Spiked? | First Spike |
|-----------|--------|-----------|------|------------|---------|-------------|
| 0 | 16 | hold | 200 | 1 | **No** | -1 |
| 1 | 16 | hold | 200 | 2 | **No** | -1 |
| **2** | **16** | **hold** | **200** | **4** | **No** | **-1** |
| 3 | 16 | hold | 200 | 8 | **No** | -1 |
| 4 | 16 | hold | 200 | 15 | **YES** | 65 |
| 5 | 16 | hold | 200 | 15 | **YES** | 65 |
| 2 | 1 | hold | 128 | 0 | YES | 35 |
| 2 | 2 | hold | 128 | 1 | YES | 37 |
| 2 | 4 | hold | 128 | 3 | YES | 41 |
| 2 | 8 | hold | 128 | 4 | **No** | -1 |

Bold row is the default configuration.

---

## Mathematical Proof

With `LEAK_SHIFT=2` and hit=1 per cycle (best case):
```
st_next = st - (st >> 2) + 1
```

Integer arithmetic fixed points:
- st=4: 4 - (4>>2) + 1 = 4 - 1 + 1 = 4  ← stable
- st=3: 3 - (3>>2) + 1 = 3 - 0 + 1 = 4  ← rises to 4
- Starting from 0: 0→1→2→3→4 (stable)

Maximum achievable state: **4**
THRESH = **16**
4 < 16 → **LIF cannot spike. Ever.**

For LEAK_SHIFT=4:
- st<16: (st>>4) = 0, so st_next = st + 1 per hit
- State rises 0→1→...→16 (spike!) in 32 hit cycles
- THRESH=16 is reachable.

---

## Mandatory Conclusion

**LIF unit is fundamentally non-spiking under current implementation.**

With `LEAK_SHIFT=2` and `THRESH=16`, the mathematical fixed point (4) is below threshold regardless of scan timing, hit density, or input frequency. The arithmetic is correct; the parameters are wrong. Fixing requires changing `LEAK_SHIFT` to ≥4 (or lowering `THRESH` to ≤4, which is not physically meaningful for motion detection).
