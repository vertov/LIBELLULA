# Diagnostics status — read this first

The two verdict documents in this tree are **stale** and are retained only for
history. They are banner-marked SUPERSEDED:

- `diagnostics/FINAL_VERDICT.md` — assumes an `(x ^ y)` LIF hash and a
  permanently silent core. Neither matches the current RTL.
- `diagnostics_full/10_FINAL_ROOT_CAUSE.md` — correct for `LEAK_SHIFT=2`, which
  is no longer the default (`LIF_LEAK_SHIFT=4` is).

## Why they no longer apply

`rtl/lif_tile_tmux.v` (current) hashes with concatenation of the high address
bits, `{in_x[hi], in_y[hi]}`, and includes a retime path
(`scan_addr_target = event_pending ? hashed_xy : eff_scan`) that forces an
event's own neuron to be serviced on the cycle it arrives. With the default
`LEAK_SHIFT=4, THRESH=16, HIT_WEIGHT=1`, a neuron under sustained hits reaches
the threshold (state = 16) at hit 15 and spikes roughly every 16 hits. This is
arithmetic, independently reproducible:

    st_next = st - (st >> 4) + 1   ->   crosses 16, spikes, resets

So the "core never spikes" conclusion is obsolete.

## Verification actually run for the `fix/pipeline-rework` branch

Simulators: Icarus Verilog 11.0 (initial run) and 12.0 (independent re-run,
2026-07-07). Results on this branch:

- `libellula_top` elaborates clean at NTRACK=1 and NTRACK=4.
- Unit testbenches PASS against the modified RTL:
  `tb_delay_lattice_rb` (rewritten windowed lattice, 10/10),
  `tb_ab_predictor` (new DIR_HINT_SHIFT path, 7/7),
  `tb_lif_tile_tmux` and `tb_lif_liveness` (SCAN_MODE=0 default),
  `tb_reichardt_ds` (10/10), `tb_burst_gate` (7/7).
- **End-to-end the pipeline now emits predictions.** `tb_e2e_motion` asserts
  `pred_valid` 3031 times (first at cycle 42). This is the proof-of-life the
  stale verdicts claimed was impossible.
- **Accuracy is tile-quantisation-limited, not tracking-limited.**
  `tb_accuracy` PASSES with `mean_x = 1.0 px, mean_y = 0.0 px`, but peak
  `err_x = 16 px` — exactly one AW=8 tile step — and the bench itself prints
  `CLAIM_CHECK PARTIAL: peak error 16px (tile-size limited)`. Earlier revisions
  of this document stated `err_x = err_y = 0`; that overstated the result.
- Full regression under iverilog 12: latency claim holds (5 cycles / 25 ns),
  1 Meps throughput and 300 Hz benches pass, all 20 scenario benches pass
  (reversal, clutter, multi-target pool included), all 3 hostile benches pass.

## Stability follow-up landed (2026-07-07)

- **CI**: `.github/workflows/ci.yml` runs the full iverilog regression
  (units, claims, scenarios, hostile, diagnostic) on every push/PR. Benches
  signal failure by printing rather than exit code, so each CI step greps
  its log for FAIL/TIMEOUT — a printed FAIL now fails the build.
- **Hard accuracy bounds**: `tb_accuracy` now FAILS (not just reports) when
  mean error > 2 px, peak x > 16 px, or peak y > 2 px. A bench that cannot
  fail its claim is documentation, not a test.
- **Background-activity filter** (`rtl/activity_filter.v`): spatiotemporal
  BAF in front of the LIF — an event passes only with own-tile or
  8-neighbour activity within AF_WINDOW cycles. Zero added latency
  (combinational pass, clocked bookkeeping), recency bit-map + timestamp
  scrubber (expiry within WINDOW..WINDOW+2^AW cycles). Default OFF at
  `libellula_top` (sparse workloads are legitimate for the bare core);
  the SoC/UAV profile enables it. Validated by `tb_activity_filter`
  (8 unit tests) and `tb_e2e_filter` (end-to-end: 10/10 injected noise
  events dropped, 1 cold-start drop, pipeline predicts normally).
- **Innovation-scheduled predictor gain** (`ab_predictor` ADAPT_GAIN) and
  **lock-gated measurement smoothing** (MEAS_FILT): alpha scales down /2
  then /4 when the smoothed residual is small AND the direction hint is
  quiet; the measurement EMA engages only in that locked-quiet regime.
  Unit-proven in `tb_ab_adaptive`: 12-16% lower tracking error under
  measurement noise, and a hover-jitter win with the EMA engaged. Both
  are OPT-IN (default 0 everywhere): with gains scheduled, the alpha
  correction no longer masks (a) the direction-hint velocity bias
  (+4 px steady offset at 1 px/update drift in tb_px_bound_300hz) and
  (b) tile-transition error spikes in tb_accuracy (peak 16 -> 52 px).
  Both interactions are properties of the hint/tile design that full
  alpha was hiding, not of the scheduler itself — see open item 6.

## Still open (not blockers, but do before trusting numbers)

1. ~~Two pipeline benches — `tb_pred_valid_golden`, `tb_pred_must_fire` — fail
   to COMPILE under iverilog 11~~ **RESOLVED by toolchain upgrade:** both
   compile and run under Icarus Verilog 12.0 (`tb_pred_must_fire` PASSES,
   `tb_pred_valid_golden` emits predictions). Use iverilog >= 12; no code
   change needed.
2. Regenerate the comparative benchmark driving the **actual RTL** (the current
   `benchmarks/` harness is a Python behavioural model, not the hardware) and
   show a regime where the spiking pipeline beats a constant-velocity baseline.
3. Tune `DIR_HINT_SHIFT` (top-level default 3) and sweep the windowed delay
   lattice depth `DW` on the clutter/noise scenarios; confirm the stronger
   direction hint and multi-slot correlation help rather than destabilise.
4. **The windowed lattice is dormant at top-level defaults.** `libellula_top`
   defaults to `DW=0`, so every top-level scenario bench exercises the legacy
   1-event window; only the unit bench (DW=2) and the SoC profile (DW=6) use
   the new multi-slot search. Add an end-to-end scenario bench at DW=6 (or
   raise the top default) so the shipped feature is on the tested path.
5. **Sub-tile accuracy.** The 16 px peak error is the AW=8 tile step: the
   predictor only ever sees tile-hashed coordinates. Feed it the raw pixel
   `x_tap`/`y_tap` (already available) or a per-tile event centroid to attack
   the <=2 px claim directly; raising AW trades area for the same effect.
6. **Direction-hint bias rework, then ADAPT_GAIN default-on.** The Reichardt
   hint adds velocity every update; at full alpha (0.75) the position
   correction cancels ~75% of the resulting offset in the output, which is
   why the bias was never visible. Any gain reduction re-exposes it. Make
   the hint bias-free (apply it only during acquisition, or high-pass it so
   sustained hints decay), re-tune the ADAPT_GAIN thresholds against the
   scenario suite, then flip ADAPT_GAIN=1 as the top-level default.
7. **Hot-pixel rate cap.** The BAF drops isolated noise but a hot pixel
   self-supports after its first event. A per-tile event-rate cap (or
   refractory counter) in `activity_filter` would close that hole cheaply.
