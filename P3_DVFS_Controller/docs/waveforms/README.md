# P3 — Waveform evidence

Behavioral simulation screenshots, AMD Vivado Simulator (XSim) v2026.1.

> **Not yet captured.** This file is the capture specification for the four
> persistence-counter waveforms. The PNG files are not in the repository yet —
> only the console transcript at
> [`../../simulation/persistence_sim_output.txt`](../../simulation/persistence_sim_output.txt)
> currently provides verification evidence for this module.

The controller FSM waveform already in the repository is at
[`../../simulation/dvfs_waveform.png`](../../simulation/dvfs_waveform.png).

## Required signals

Every persistence-counter capture must show all seven of these in the Wave
window:

```
clk
rst_n
class_valid
workload_class[1:0]
dut.persist_count
stable_class[1:0]
stable_valid
```

Testbench: `tb/tb_p3_persistence_counter.v`, `PERSIST_THRESHOLD = 3`.
Clock period 10 ns. Full run 0–661 ns. Locate each region using the
`TEST n:` markers printed in the Tcl console.

## Captures

| File | Testbench region | What it must demonstrate |
|------|------------------|--------------------------|
| `persistence_threshold.png` | TEST 1 | A HIGH class is accepted only after 3 consecutive valid epochs. `persist_count` steps 1 → 2 → 3; `stable_valid` rises on the third epoch, not earlier. |
| `persistence_class_change.png` | TEST 2 | Switching HIGH → LOW requires 3 new consecutive epochs. `stable_class` holds HIGH while `persist_count` rebuilds, then switches to LOW. |
| `persistence_reset.png` | TEST 3 | `rst_n` going low clears `persist_count` and `stable_valid`, and returns `stable_class` to `2'b00`. |
| `persistence_invalid_class.png` | TEST 6 | `workload_class = 2'b11` interrupts the streak: `persist_count` clears and the HIGH count must restart from 1. |

## Scope

These four screenshots plus the console transcript are the agreed verification
evidence for this checkpoint. They demonstrate directed functional behaviour
only — no timing, synthesis or gate-level verification, and no integration with
the controller FSM. Section 7 of [`../../README.md`](../../README.md) lists what
remains uncovered.

Do not commit `.wdb` simulation databases; they are excluded by `.gitignore`.
