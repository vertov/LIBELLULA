## Comparative Benchmark Suite

The Python harness in this folder synthesizes six stress scenarios and evaluates
Libellula alongside conventional trackers.

### Run

```bash
python3 benchmarks/run_benchmarks.py
```

Results are written to `benchmarks/out/` as:

- `benchmark_results.csv` – machine-readable metrics for each tracker/scenario
- `benchmark_results.json` – same data in JSON form
- `benchmark_report.md` – per-scenario tables for all trackers plus method notes

### Notes

* The harness retimes event streams so that hashed addresses align with the
  Libellula LIF scanner, without changing the original scenario timelines used
  for scoring.
* These scenarios are comparative stress tests, not the release claim benches.
  The report lists every tracker per scenario (prediction count, MAE at h=1
  and h=8, false-lock rate, latency, composite score).
* Pairing (v23): the RTL emits a prediction only for events that pass the LIF
  and burst gate, so `tb_benchmark_driver.v` labels each prediction with the
  newest event presented at least one pipeline depth earlier. v22 paired
  prediction k with event k through a FIFO, which mislabelled every
  prediction after the first and reported MAE of 80–210 px.
* Baseline latencies are nominal constants in `baselines.py`; only the
  Libellula latency is measured.
* `tiny_learned` (v23) is a normalised-LMS velocity regressor. The v22 version
  regressed on raw pixel coordinates and diverged to NaN.
* If the RTL emits no predictions for a scenario, the CSV entry for
  `libellula_core` is left blank, and the markdown report records the baseline
  winner.
* The baseline implementations live in `benchmarks/baselines.py` and can be
  extended or replaced as needed by editing the factory in `build_baselines()`.
