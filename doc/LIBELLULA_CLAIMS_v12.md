# LIBELLULA Core v22 — Claims Validation

This document summarizes the technical claims supported by the LIBELLULA Core v22 RTL and the manner in which those claims are validated through simulation. Validation is performed at the RTL level using cycle-accurate testbenches and structural inspection.

---

## 1. Bounded Low Latency

**Claim:**  
The core exhibits fixed, bounded latency from accepted input event to predictor output.

**Validation:** `tb_latency`

**Result:**
```
LATENCY_CYCLES = 5
PASS
```

**Interpretation:**
The current pipeline produces a consistent 5-cycle latency. At 200 MHz, this corresponds to 25 ns, well below one microsecond. The improvement from 6 to 5 cycles followed making `aer_rx` fully combinational. Latency is independent of scene complexity and event history.

---

## 2. Bounded Prediction Error Under Constant Motion

**Claim:**  
Under constant-velocity motion, the predictor maintains bounded position error.

**Validation:** `tb_px_bound_300hz`

**Result:**  
```
PASS
```

**Interpretation:**  
The test confirms correct fixed-point α–β predictor behavior and stable convergence after a short warmup period. This validates the algebraic correctness of the predictor implementation under controlled motion.

---

## 3. Sustained Event Throughput

**Claim:**  
The core sustains high event rates without internal state loss or corruption.

**Validation:** `tb_aer_throughput_1meps`

**Result:**  
```
PASS
```

**Interpretation:**  
Simulation confirms that the ingress path and internal pipeline accept and process events at rates consistent with 1 Meps under the implemented handshake semantics, with no dropped or corrupted events.

---

## 4. Event-Driven Activity Scaling

**Claim:**  
Internal switching activity scales with event activity rather than elapsed time.

**Validation:** `tb_power_lo`, `tb_power_hi`

**Result (Representative):**  
Higher event density produces proportionally higher toggle activity, while sparse input produces minimal switching.

**Interpretation:**  
This confirms that computation and activity are driven by events, supporting efficient operation under sparse or intermittent visual input.

---

## 5. Coherent Processing Pipeline

**Claim:**  
LIBELLULA Core v22 implements a complete and coherent event-processing pipeline from ingress through motion estimation and prediction.

**Validated Stages:**  
- `aer_rx`  
- `lif_tile_tmux`  
- `delay_lattice_rb`  
- `reichardt_ds`  
- `burst_gate`  
- `ab_predictor`  
- `conf_gate`

**Validation:**  
`tb_cv_linear`, `tb_cross_clutter`, `tb_accel_limit`

**Interpretation:**  
These tests exercise multiple stages together and confirm correct signal propagation, alignment, and functional interaction across the pipeline.

---

## 6. Deterministic Behavior

**Claim:**  
For a given input sequence and initial state, the core produces repeatable outputs.

**Basis:**  
- Single-writer sequential logic throughout the RTL.  
- Explicit removal of nonblocking assignment ordering hazards.  
- State updates occur only under defined control conditions.

**Validation:**  
Repeated simulations with identical stimuli produce identical results.

---

## Test Execution

Core tests:
```bash
cd sim
make test
```

Individual tests:
```bash
make latency
make px300
make meps
make power
```

Toolchain:
- Icarus Verilog (SystemVerilog 2012)
- VVP runtime
- Optional Python toggle analysis

---

## Validation Scope

The following aspects are validated at RTL level:

- Deterministic operation  
- Fixed, bounded latency  
- Sustained internal throughput  
- Predictor algebraic correctness  
- Event-driven activity scaling  
- Pipeline coherence  

System-level performance beyond the core (sensors, optics, external protocols) is outside the scope of this validation.

---

## Summary

The LIBELLULA Core v22 claims are supported by targeted RTL simulation and structural analysis. The design demonstrates deterministic, event-driven operation with bounded latency, bounded resources, and coherent predictive motion processing consistent with the implemented architecture.
