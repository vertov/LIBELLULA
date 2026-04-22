# Phase 7 — Emission Gate Analysis

**Independent verification 2026-04-11.** Static cone-of-logic trace plus simulation observation.

---

## Gate Ladder: pred_valid Cone of Logic

Traced from `pred_valid` back to input ports in `rtl/libellula_top.v`.

```
pred_valid
  <- ab_predictor.out_valid  [line 175: .out_valid(pred_valid)]
     <- ab_predictor.in_valid = bg_v  [line 172]
        <- burst_gate.out_valid = bg_v  [line 144]
           <- burst_gate.in_valid = ds_v  [line 143]
              <- reichardt_ds.out_valid = ds_v  [line 118]
                 <- reichardt_ds.in_valid = lif_v_d1  [line 117]
                    <- lif_v_d1 (1-cycle delay of lif_v)  [line 96-101]
                       <- lif_tile_tmux.out_valid = lif_v  [line 71]
                          <- spike = (st_next >= THRESH)  [lif_tile_tmux.v:70]
                             <- st_next = st_after_leak + hit_s1
                                <- st_after_leak = st_read - (st_read >> LEAK_SHIFT)
                                   <- st_read = state_mem[scan_addr_s1]
                                <- hit_s1 (Stage-0 register of hit_comb)
                                   <- hit_comb = in_valid && (hashed_xy == scan_addr)
```

---

## Gate-by-Gate Observation Table

| Gate term | Source location | Observed true count | Blocks emission? | Why blocked |
|-----------|-----------------|---------------------|-----------------|-------------|
| `hit_comb` | lif_tile_tmux.v:45 | sporadic | Not primary — fires occasionally | Must align with scan; only 1/256 duty cycle |
| `spike = st_next >= THRESH` | lif_tile_tmux.v:70 | **0** in all runs | **YES — PRIMARY** | st_next max=4 < THRESH=16 |
| `lif_v` (= out_valid && !rst) | lif_tile_tmux.v:34 | **0** | Yes (consequential) | Driven by spike |
| `lif_v_d1` | libellula_top.v:96 | **0** | Yes (consequential) | Delayed from lif_v |
| `v_e..v_sw` (delay taps) | delay_lattice_rb.v:146 | **0** | Yes (consequential) | in_valid = lif_v = 0 |
| `ds_v` (Reichardt) | reichardt_ds.v:102 | **0** | Yes (consequential) | in_valid = lif_v_d1 = 0 |
| `bg_v` (burst gate) | burst_gate.v:95 | **0** | Yes (consequential) | in_valid = ds_v = 0 |
| `pred_valid` | ab_predictor.v:44 | **0** | Yes (consequential) | in_valid = bg_v = 0 |

---

## Secondary Gate: Burst Hysteresis

`burst_gate` uses hysteresis (TH_OPEN=3, TH_CLOSE=1, WINDOW=16). The gate will stay closed until 3 or more Reichardt events arrive in 16 cycles. Since ds_v never fires, gate_state remains 0 permanently.

This is NOT an additional blocker — it would work correctly if ds_v ever fired. It has never been exercised.

---

## Conclusion

The emission path has exactly one primary blocker: `spike = (st_next >= THRESH)` in `lif_tile_tmux`. Everything downstream is a consequential zero. If this single comparator were to become true (by fixing LEAK_SHIFT), the remaining gates would be exercised for the first time.

The burst gate hysteresis threshold (TH_OPEN=3) is the next most restrictive gating downstream — once lif_v fires, Reichardt would need to accumulate 3+ events per 16 cycles. With continuous LIF spiking this is achievable, but has never been validated.
