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
- `benchmark_report.md` – terse summary of wins/ties/losses plus assumptions

### Notes

* The harness retimes event streams so that hashed addresses align with the
  Libellula LIF scanner, without changing the original scenario timelines used
  for scoring.
* If the RTL emits no predictions for a scenario, the CSV entry for
  `libellula_core` is left blank, and the markdown report records the baseline
  winner.
* The baseline implementations live in `benchmarks/baselines.py` and can be
  extended or replaced as needed by editing the factory in `build_baselines()`.
