# Phase 3 — Scan/Hash Contract Analysis

**Independent verification 2026-04-11.**

Bench: `tb_scan_hash_diag.v` (modes 0-3) compiled with `LIBELLULA_STAGE_DIAG`.
Script: `python3 diagnostics_full/scripts/run_scan_contract.py`.

Modes:
1. `unscheduled` (mode=0): emit events every 2 cycles regardless of `scan_addr`.
2. `wait_for_match` (mode=1): wait until `scan_addr == hash(x,y)` before issuing.
3. `hold_until_match` (mode=2): assert `aer_req` continuously until scanner matches.
4. `retry_three_times` (mode=3): fire the event up to three times if missed.

---

## Results

| Mode | events | LIF spikes | Stage log |
|------|--------|------------|-----------|
| `unscheduled` | 32 | 0 | first_lif=-1 |
| `wait_for_match` | 32 | 0 | first_lif=-1 |
| `hold_until_match` | 7,882 | 0 | first_lif=-1 |
| `retry_three_times` | 96 | 0 | first_lif=-1 |

---

## Analysis

**Why wait_for_match fails despite scan alignment:**
The bench increments `target_x` by 1 for each event, so each event maps to a different LIF
address: `hash(target_x+i, target_y)` differs for each `i`. Even when every event is perfectly
timed to match its own hash window, each LIF neuron receives at most 1 hit. One hit produces
state=1, far below THRESH=16.

**Why hold_until_match (7,882 events) still fails:**
Mode 2 holds `aer_req=1` while waiting for scan to match. This generates many events for the
same (x, y) until the scan arrives, but the bench advances `target_x` after each hold.
Effective per-neuron hit count remains ~1. Even if all 7,882 events went to one neuron, the
LIF fixed point (LEAK_SHIFT=2 -> max state=4) makes THRESH=16 unreachable.

**Scan/hash contract:**
The condition `hit_comb = in_valid && (hashed_xy == scan_addr)` is a strict one-cycle gate.
With AW=8 and free-running scan, each address is open for exactly 1 cycle per 256 cycles.
This requirement is not documented anywhere in the repo.

---

## Mandatory Conclusion

The scan/hash rule is a **valid but undocumented contract** that causes unscheduled events to
be silently dropped. Satisfying the contract is necessary but not sufficient to produce LIF
spikes: even perfectly aligned events fail because LEAK_SHIFT=2 makes the accumulator fixed
point (4) permanently below THRESH=16.

**The scan/hash issue is a secondary (compounding) problem, not the primary blocker.
The primary blocker is the LIF parameter mismatch identified in Phase 2.**
