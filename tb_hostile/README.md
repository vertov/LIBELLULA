# Hostile Verification Pass (Failure-Mode Focus)

These benches are intended to complement the existing functional suite by stressing *failure modes* and “evaluation-grade” contracts (reset, pathological stimuli, overload semantics).

## Why these benches exist

Most of the v11 functional benches validate *nominal* behaviour (latency, bounded error in controlled motion, 1 Meps ingress, clutter cases, etc.). The benches here focus on conditions that cause real integrations to fail in the field or during customer review:

- Reset asserted mid-stream
- Inputs held in illegal or ambiguous states (e.g., AER request stuck high)
- Randomized burst patterns (idle, storms, mixed polarity)
- X/Z immunity (no unknown propagation)

## Key behavioural contracts this pass makes explicit

1. **Reset contract**
   - While `rst=1`, all module “valid” outputs must be deasserted.
   - When `rst` is asserted asynchronously in time (mid-stream), valid outputs must drop within 1 cycle.
   - After `rst` deasserts, behaviour must be deterministic again.

2. **Ingress protocol contract (`aer_rx`)**
   - The current `aer_rx` is a *simplified* level-sensitive protocol: if `aer_req` remains high, multiple events will be generated (duplicates). This is acceptable for certain evaluation contexts but must be explicit.

3. **No-X contract (evaluation-grade)**
   - No test should ever observe X/Z on outputs. Unknowns are treated as failures.

## Benches

- `tb_reset_midstream_top.v`
  - Resets the full pipeline mid-stream and checks reset/valid behaviour and deterministic re-entry.

- `tb_aer_req_stuck_high.v`
  - Holds `aer_req` high for N cycles and verifies the documented duplicate-event behaviour.

- `tb_random_stress_top.v`
  - Randomized event bursts and occasional reset pulses; checks for unknowns and reset-valid behaviour.

## Tooling note

These benches are written to be compatible with common simulators (Icarus/ModelSim/Questa/VCS). Run them with the same RTL set used by the other benches.
