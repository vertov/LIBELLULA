Selected on val: without ESTMD polarity correlation

| Variant (each tuned on val) | val IoU | val Pd | test IoU | test ACC | test Pd | test precision | false clusters / 50 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| Full model (all stages) | 0.832 | 0.875 | 0.670 | 0.780 | 0.858 | 0.826 | 0.54 |
| without ESTMD polarity correlation (selected) | 0.838 | 0.895 | 0.667 | 0.845 | 0.883 | 0.760 | 0.64 |
| without flicker habituation | 0.811 | 0.841 | 0.630 | 0.777 | 0.854 | 0.769 | 0.94 |
| without centre-surround inhibition | 0.723 | 0.655 | 0.666 | 0.750 | 0.643 | 0.855 | 0.47 |
| without activity term in surround | 0.790 | 0.875 | 0.544 | 0.851 | 0.889 | 0.601 | 0.87 |
| without stationarity check | 0.826 | 0.845 | 0.732 | 0.767 | 0.822 | 0.941 | 0.48 |
| without tracker (per-event score only) | 0.391 | 0.927 | 0.421 | 0.767 | 0.923 | 0.483 | 2.27 |
| density only (no ESTMD, habituation or surround) | 0.592 | 0.704 | 0.721 | 0.753 | 0.805 | 0.944 | 0.40 |

Selected on test: Fa (released scorer) = 7.13e-06; events = 2074586; target windows = 5228
