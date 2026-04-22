# Libellula Comparative Benchmark

Assumptions:
- Prediction error measured as Euclidean MAE at horizons h=1,4,8 cycles.
- Libellula horizon >1 estimates extrapolated from successive predictions.
- False-lock defined as being locked while error >5 px at horizon-1.
- Recovery evaluated from occlusion metadata when available.
- Compute-cost proxy derived from normalized per-event operations; Libellula fixed to 1.0.

| Scenario | Outcome | Notes |
|---|---|---|
| linear_motion | Win: event_motion | lowest composite score 1.058 |
| abrupt_acceleration | Win: event_motion | lowest composite score 1.609 |
| distractor_crossings | Win: constant_velocity_nn | lowest composite score 1.897 |
| partial_occlusion | Win: event_motion | lowest composite score 2.340 |
| noise_bursts | Win: constant_velocity_nn | lowest composite score 3.199 |
| latency_stress | Win: event_motion | lowest composite score 0.943 |