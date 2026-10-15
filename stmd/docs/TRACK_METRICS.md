# Track-level metrics (v26)

The EV-UAV scorer answers "which events belong to the target?" and counts every labelled background pixel as a separate false alarm. A detector's user asks four different questions; `libstmd/trackmetrics.py` answers them from the model's confirmed-track log.

**Inputs.** Ground-truth target events with identities; the model's list of (time, track id, x, y) records, one per update of a confirmed, moving track.

**Ground truth per window.** Time is cut into 50 ms windows. A target is *present* in a window if it has at least 2 labelled events there; its position is their centroid.

**Match.** A track record matches a target when the target is present in the record's window and the record lies within 10 px (Chebyshev) of the centroid.

| Metric | Definition | Direction |
|---|---|---|
| `target_detected_rate` | Share of target identities matched by at least one record at any time | higher |
| `time_to_first_detect_ms_median` | Median, over detected targets, of first matching record time minus the target's first event time | lower |
| `window_coverage` | Share of (target, window) pairs where the target is present and some record matches it. Track-level analogue of Pd | higher |
| `false_tracks_per_min` | Confirmed tracks that never match any target, per minute of data | lower |
| `false_track_time_frac` | Share of (track, window) pairs with no match: time spent reporting a non-target position | lower |
| `loc_error_px_median`, `_p90` | Distance from matching records to the target centroid | lower |

Notes.
- A track that matches once is not false even if it drifts afterwards; the drift shows up in `false_track_time_frac`.
- Tracks that stopped moving (stationarity check) are not logged, so a muted glare track is not counted.
- Gate and window are fixed (10 px, 50 ms). Targets average 6×5 px.
- These metrics are reported alongside the EV-UAV metrics, not instead of them.
