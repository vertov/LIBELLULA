# Phase 1 — Reproduce Prior Failure

**Independent verification run 2026-04-11. Simulator: iverilog 12.0 / vvp.**

Commands executed directly (not via Python wrapper, for independent verification):

```bash
make -C sim build/tb_pred_valid_golden IVERILOG="iverilog -DLIBELLULA_STAGE_DIAG"
vvp sim/build/tb_pred_valid_golden \
  +TEST_NAME=full_gp +EVENT_SPACING=1 +EVENT_COUNT=64 \
  +RESET_CYCLES=64 +QUIET_CYCLES=32 \
  +STAGE_OUT=diagnostics_full/out/stage_golden.log

make -C sim build/tb_pred_must_fire IVERILOG="iverilog -DLIBELLULA_STAGE_DIAG"
vvp sim/build/tb_pred_must_fire +X_STEP=1 \
  +STAGE_OUT=diagnostics_full/out/stage_must_fire.log
```

Both benches rebuilt from source; no cached artifacts used.

## Runs

| Test | Stimulus | Result |
|------|----------|--------|
| `golden_unscheduled` | `tb_pred_valid_golden`, 64 monotonic events, no scan scheduling | `pred_valid_count = 0`, stage log shows `events=64` yet `lif=delay=reichardt=burst=pred=0`. |
| `must_fire_aligned` | `tb_pred_must_fire`, events hashed/aligned with scan address | Still `pred_valid_count = 0`; stage log remains zero past input events. |

CSV: `diagnostics_full/out/repro_runs.csv` (plus JSON) records full details including cycle counts and stage diagnostics.

## Conclusion

Reproduction **PASS**: both previously reported negative outcomes are confirmed. Even with a hash-aligned must-fire stimulus, no stage past the AER receiver activates; the earliest nonzero stage is still the LIF tile (and even it shows zero spikes). No discrepancies with prior evidence were found.
