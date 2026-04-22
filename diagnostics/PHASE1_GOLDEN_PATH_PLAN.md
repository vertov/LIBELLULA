# Phase 1 — Golden-Path Emission Plan

**Objective:** craft the simplest deterministic stimulus that *should* force `pred_valid` high if the RTL is healthy, using repo-native tooling (Icarus) and existing pipeline parameters (XW=10, YW=10, AW=8, DW=4, PW=16).

## Stimulus strategy
1. **Single target, constant velocity:** replicate the intent of `tb_cv_linear` but strip out any comparisons or assertions so we can sweep reset/warm-up and event density.
2. **Hand-crafted AER sequence:** drive `aer_req` high for exactly one cycle per event, increment `aer_x` each time, keep `aer_y` fixed, and emit both ON/OFF polarities if necessary.
3. **Scan alignment:** continue using the standard `scan_addr<=scan+1` pattern from repo benches.
4. **Warm-up delays:** hold reset for ≥32 cycles, then insert a programmable quiet period before events.
5. **Density sweep:** run multiple sub-tests varying event spacing (1, 2, 4 cycles) and track count (32, 64, 128) to see whether the delay lattice / burst gate needs higher density.

## Implementation steps
1. Add `tb/tb_pred_valid_golden.v` (pure Verilog, following repo style) that:
   - Exposes parameters for `RESET_CYCLES`, `QUIET_CYCLES`, `EVENT_COUNT`, `EVENT_SPACING`.
   - Counts `pred_valid` assertions, records first assertion cycle, dumps summary via `$display`.
   - Fails if simulation reaches a configurable max cycle without finishing.
2. Add a small runner script `diagnostics/run_phase1_golden.py` to sweep a handful of parameter sets, invoke `make -C sim build/tb_pred_valid_golden`, run `vvp`, parse the summary lines, and emit:
   - `diagnostics/out/golden_path_results.csv`
   - `diagnostics/out/golden_path_results.json`
3. Record failure when `pred_valid_count == 0` for all sweeps; otherwise capture the earliest successful configuration.

## Planned sweep (test_name → params)
| test_name | event_rate (cycles between events) | event_count | reset_cycles | warmup_cycles |
|-----------|------------------------------------|-------------|--------------|---------------|
| GP1       | 1                                  | 64          | 64           | 32            |
| GP2       | 2                                  | 64          | 64           | 32            |
| GP3       | 1                                  | 128         | 64           | 64            |
| GP4       | 1                                  | 64 (Y jitter) | 64        | 32            |

`Y jitter` variant wiggles `aer_y` every other event to force multi-direction motion if required.

## Success criteria
* PASS if **any** sweep logs `pred_valid_count > 0`.
* Otherwise FAIL and proceed to Phase 2 instrumentation.

## Tooling
* Simulator: `iverilog` + `vvp` (repo default).
* Deterministic seeds only (hand-coded events).
