# Libellula Comparative Benchmark

Assumptions:
- Prediction error measured as Euclidean MAE at horizons h=1,4,8 cycles.
- Libellula horizon >1 estimates extrapolated from successive predictions.
- False-lock defined as being locked while error >5 px at horizon-1.
- Recovery evaluated from occlusion metadata when available.
- Compute-cost proxy derived from normalized per-event operations; Libellula fixed to 1.0.

| Scenario | Outcome | Notes |
|---|---|---|
| linear_motion | Win: event_motion | lowest composite score 1.058; libellula_core preds=12, mae_h1=138.885, false_lock=1.000 |
| abrupt_acceleration | Win: event_motion | lowest composite score 1.609; libellula_core preds=13, mae_h1=123.352, false_lock=1.000 |
| distractor_crossings | Win: constant_velocity_nn | lowest composite score 1.897; libellula_core preds=31, mae_h1=129.259, false_lock=1.000 |
| partial_occlusion | Win: event_motion | lowest composite score 2.340; libellula_core preds=11, mae_h1=98.450, false_lock=1.000 |
| noise_bursts | Win: constant_velocity_nn | lowest composite score 3.199; libellula_core preds=12, mae_h1=81.820, false_lock=1.000 |
| latency_stress | Win: event_motion | lowest composite score 0.943; libellula_core preds=43, mae_h1=213.682, false_lock=1.000 |