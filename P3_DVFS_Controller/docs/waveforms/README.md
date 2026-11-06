# P3 — Waveform evidence

Behavioral simulation screenshots, AMD Vivado Simulator (XSim) v2026.1.
Verilog-2001, functional simulation only.

All captures below were taken from the Vivado project at
`C:\Users\anand\sruthi\dvfs` and copied here. The originals are kept outside the
repository and are not tracked.

---

## 1. Persistence counter — `p3_persistence_counter.v`

Testbench: [`../../tb/tb_p3_persistence_counter.v`](../../tb/tb_p3_persistence_counter.v),
`PERSIST_THRESHOLD = 3`, clock period 10 ns.

| File | Sim time | What it shows | Verification purpose |
|------|----------|---------------|----------------------|
| `p3_persistence_counter_waveform.png` | 0–531 ns | Full Vivado window: Wave view with `clk`, `rst_n`, `class_valid`, `workload_class[1:0]`, `stable_class[1:0]`, `stable_valid`, `persist_count[1:0]`, `last_class[1:0]`, `errors[31:0]`, plus the Tcl console. | Shows `persist_count` stepping 1 → 2 → 3 before `stable_valid` rises, `stable_class` holding its previous value while a new class rebuilds the count, reset clearing the count, and `errors` remaining `0`. Console ends `ALL TESTS PASSED`, `$finish` at 531 ns. |
| `p3_persistence_extended_tests.png` | 0–661 ns | The same testbench after the extended cases were added, including the reserved class `2'b11` in the `workload_class` trace. | Shows an invalid/interrupting class breaking the streak so the count restarts, and the longer run still finishing with `errors = 0`. `$finish` at 661 ns. |

The matching console transcript is at
[`../../simulation/persistence_sim_output.txt`](../../simulation/persistence_sim_output.txt).

> The two captures are successive runs of the **same** testbench, before and
> after the extended cases were added. The later capture supersedes the earlier
> one; the earlier one is kept because it is the run the persistence console
> transcript in `simulation/` was taken from.

---

## 2. Hysteresis level-selection logic — `p3_hysteresis_controller.v`

Testbench: [`../../tb/tb_p3_hysteresis_controller.v`](../../tb/tb_p3_hysteresis_controller.v).
Purely combinational DUT; the testbench applies directed vectors with a 10 ns
settle between each.

| File | What it shows | Verification purpose |
|------|---------------|----------------------|
| `p3_hysteresis_console_test.png` | Full XSim console transcript of the directed test run. | The pass/fail record for every vector, ending `TOTAL CHECKS: 17`, `PASSED: 17`, `FAILED: 0`, `ALL HYSTERESIS TESTS PASSED`. This is the primary evidence for this module. |
| `p3_hysteresis_waveform.png` | Wave view with `gpu_utilization[7:0]`, `utilization_valid`, `current_level[1:0]`, `recommended_level[1:0]`, `pass_count[31:0]`, `fail_count[31:0]` and the level constants. | Corroborates the console: `recommended_level` tracks the expected value as the vectors step, `pass_count` climbs monotonically to 17, and `fail_count` stays `0` for the whole run. Also shows `recommended_level` holding `current_level` across the `utilization_valid = 0` vector. |

### Recorded result

**17 checks, 17 passed, 0 failed.**

Coverage of the 17 checks:

- Upshifts from LOW: → MEDIUM and → HIGH (direct).
- Downshifts from MEDIUM and HIGH, including HIGH → LOW (direct).
- Hold cases: LOW, MEDIUM and HIGH each remaining at their current level.
- All six exact threshold boundaries: 15, 25, 40, 55, 75, 85.
- `utilization_valid = 0` holds the current level.
- Reserved level `2'b11` in, `2'b11` out — current RTL behaviour, recorded as
  observed, not as an agreed requirement.

### Thresholds are provisional

The six utilization thresholds exercised here (15 / 25 / 40 / 55 / 75 / 85) are
**proposed P3 design parameters only**. They have not been validated against any
workload and have not been agreed with the P2 owner — see
[`../hysteresis_architecture.md`](../hysteresis_architecture.md) section 3 and
open item 1. They are currently hard-coded in the RTL; exposing them as module
parameters is still outstanding.

The directed tests confirm that the RTL implements these particular numbers
consistently. They do **not** confirm that these are the right numbers.

---

## 3. Controller FSM — `p3_dvfs_controller.v`

The FSM voltage/PLL sequencing waveform is already in the repository at
[`../../simulation/dvfs_waveform.png`](../../simulation/dvfs_waveform.png).
A later re-capture of the same testbench run exists outside the repository; it
shows the same signals over the same run and was **not** added here, to avoid
committing a duplicate.

---

## 4. Scope and limits

- Behavioral (functional) simulation only. No timing, synthesis, or gate-level
  verification. No hardware run.
- Directed vectors only. No constrained-random stimulus, no coverage model, no
  assertions.
- **The persistence counter, the hysteresis logic and the controller FSM were
  each simulated on their own, against their own testbench. They are not wired
  together. No integrated simulation of the three has been run, and this
  checkpoint is not evidence that they work together.**
- Section 7 of [`../../README.md`](../../README.md) lists what remains
  uncovered for this block.

Do not commit `.wdb` simulation databases or other XSim output; they are
excluded by the root `.gitignore`.
