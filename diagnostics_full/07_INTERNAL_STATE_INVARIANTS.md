# Phase 6 — Internal State Invariants

**Independent verification 2026-04-11.**

---

## Invariant Results Summary

| Invariant | Result | Evidence |
|-----------|--------|----------|
| Accumulator can reach THRESH=16 with LEAK_SHIFT=2 | **FAIL** | peak=4 in all runs; math: fixed point at 4 |
| Accumulator correctly increments on hit | PASS | state goes 0->1->2->3->4 correctly |
| Leak causes premature cap below threshold | **FAIL** | leak=1 at st=4 exactly balances hit=1 |
| State stable between free-run scan visits | **FAIL** | final_state=0 in free-run mode; decays to zero |
| Hit detection logic fires correctly | PASS | hit_comb=1 when in_valid=1 AND scan matches hash |
| THRESH reachable with LEAK_SHIFT=4 | PASS (non-default) | peak=15 spiked=1 at cycle 65 |
| Reset polarity correct | PASS | state_mem initialized to 0; out_valid gated with !rst |
| Output gate permanently masked | PASS (not masked) | ab_predictor output logic is sound; never triggered |
| Signed/unsigned interpretation correct | PASS | dir_x/dir_y correctly sign-extended in ab_predictor |
| Coordinate hash always in-range | PASS | hashed_xy = (x ^ y) & ADDR_MASK always in [0, 2^AW-1] |
| Burst gate can open | PASS (conditional) | hysteresis logic correct; never triggered in practice |

---

## Critical Detail: Accumulator Fixed Point

`st_next = st - (st >> 2) + hit` with LEAK_SHIFT=2, hit = 0 or 1:

```
st=0  hit=1: next = 0-0+1 = 1
st=1  hit=1: next = 1-0+1 = 2   (1>>2=0)
st=2  hit=1: next = 2-0+1 = 3   (2>>2=0)
st=3  hit=1: next = 3-0+1 = 4   (3>>2=0)
st=4  hit=1: next = 4-1+1 = 4   (4>>2=1)  <- FIXED POINT
st=4  hit=0: next = 4-1+0 = 3   (decays)
```

Starting from 0 with 1 hit per cycle: state converges to 4 and stays there.
THRESH=16 is unreachable. This is a parameter defect, not an arithmetic bug.

---

## Downstream Stage Health (static analysis, never triggered)

- `delay_lattice_rb`: ring buffer initialized to zero; correlation match logic correct; no bug.
- `reichardt_ds`: accumulator zero; decay logic verified; no signedness bug.
- `burst_gate`: hysteresis logic correct; TH_OPEN=3 in WINDOW=16 is physically reasonable.
- `ab_predictor`: initialized flag, outlier rejection, and Q8.8 arithmetic are all correct.

None of these stages have arithmetic, signedness, or reset bugs. They are dormant, not broken.
