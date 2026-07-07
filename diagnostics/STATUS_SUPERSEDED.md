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

Simulator: Icarus Verilog 11.0. Results on this branch:

- `libellula_top` elaborates clean at NTRACK=1 and NTRACK=4.
- Unit testbenches PASS against the modified RTL:
  `tb_delay_lattice_rb` (rewritten windowed lattice, 10/10),
  `tb_ab_predictor` (new DIR_HINT_SHIFT path, 7/7),
  `tb_lif_tile_tmux` and `tb_lif_liveness` (SCAN_MODE=0 default),
  `tb_reichardt_ds` (10/10), `tb_burst_gate` (7/7).
- **End-to-end the pipeline now emits predictions.** `tb_e2e_motion` asserts
  `pred_valid` repeatedly; `tb_accuracy` tracks a moving target with
  `err_x = err_y = 0` on its stimulus. This is the proof-of-life the stale
  verdicts claimed was impossible.

## Still open (not blockers, but do before trusting numbers)

1. Two pipeline benches — `tb_pred_valid_golden`, `tb_pred_must_fire` — fail to
   COMPILE under iverilog 11 due to SystemVerilog `void'(...)`/`$value$plusargs`
   usage. This is a **pre-existing** testbench/toolchain issue (unrelated to the
   RTL changes here); fix the benches or build them with a fuller SV frontend.
2. Regenerate the comparative benchmark driving the **actual RTL** (the current
   `benchmarks/` harness is a Python behavioural model, not the hardware) and
   show a regime where the spiking pipeline beats a constant-velocity baseline.
3. Tune `DIR_HINT_SHIFT` (top-level default 3) and sweep the windowed delay
   lattice depth `DW` on the clutter/noise scenarios; confirm the stronger
   direction hint and multi-slot correlation help rather than destabilise.
