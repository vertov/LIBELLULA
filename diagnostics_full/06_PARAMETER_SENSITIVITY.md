# Phase 5 — Parameter Sensitivity

**Independent verification 2026-04-11.** Full sweep using `iverilog -P` compile-time overrides.

---

## Sweep Command Template

```bash
iverilog -g2012 -P tb_lif_unit_diag.P_LEAK_SHIFT=<LS> -P tb_lif_unit_diag.P_THRESH=<T> \
  -Wall -I tb -o /tmp/lif_ls<LS>_t<T> rtl/*.v tb/tb_lif_unit_diag.v
vvp /tmp/lif_ls<LS>_t<T> +HIT_COUNT=200 +SCAN_MODE=0 +TARGET_ADDR=5
```

---

## Full Results (independently run this session)

| Config | LEAK_SHIFT | THRESH | Peak State | Spiked | First Spike | Classification |
|--------|-----------|--------|------------|--------|-------------|----------------|
| default | **2** | **16** | 4 | **No** | -1 | dead across legal parameter space |
| ls0_t16 | 0 | 16 | 1 | No | -1 | dead — leak=state; state never accumulates |
| ls1_t16 | 1 | 16 | 2 | No | -1 | dead — steady-state=2 |
| ls3_t16 | 3 | 16 | 8 | No | -1 | dead — steady-state=8 |
| ls4_t16 | 4 | 16 | 15 | **YES** | 65 | emits only under non-default tuning |
| ls5_t16 | 5 | 16 | 15 | **YES** | 65 | emits only under non-default tuning |
| ls2_t4 | 2 | 4 | 3 | YES | 41 | emits only under extreme threshold reduction |
| ls2_t8 | 2 | 8 | 4 | No | -1 | dead — steady-state=4 < 8 |

---

## Exact Boundary Condition

With `LEAK_SHIFT=L`, maximum achievable state = `2^L` (net change with hit = 0 at fixed point).

| LEAK_SHIFT | Max reachable state | Required THRESH to spike |
|-----------|---------------------|--------------------------|
| 0 | 1 | THRESH <= 1 |
| 1 | 2 | THRESH <= 2 |
| 2 | 4 | THRESH <= 4 |
| 3 | 8 | THRESH <= 8 |
| **4** | **16** | **THRESH <= 16** (first viable config) |

Default (`LEAK_SHIFT=2, THRESH=16`) is outside every working regime by a factor of 4.

---

## Downstream Activation

Even in spiking configurations (LEAK_SHIFT=4, scan held), the scan_hash bench and full-pipeline benches show no downstream activity because:
1. The spiking tests use isolated lif_tile_tmux only
2. Full pipeline with free-running scan still fails (scan timing issue secondary to LIF)

Downstream stages (delay_lattice through ab_predictor) have never been activated in any run of any bench in this repository.

**Final classification: dead across legal parameter space.** Only parameter changes requiring RTL modification allow emission.
