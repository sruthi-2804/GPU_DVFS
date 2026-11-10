# P1 — characterization model and parameters

Everything P1 needs from Cadence, and what the simulation currently assumes
instead. **No number in this document is measured silicon or Cadence data.**
Every frequency, period, settling time and energy figure is an illustrative
placeholder chosen so the model runs and the tests have something to check.

Companion documents: [`p1_pll_interface.md`](p1_pll_interface.md) for the port
contract, [`p1_pll_architecture.md`](p1_pll_architecture.md) for the internal
design.

---

## 1. Frequency-state encoding

Unchanged from Session 1 and shared across P1 to P4. Fixed by the root
[`README.md`](../../README.md); do not change it.

| Code | State |
|------|-------|
| `2'b00` | LOW |
| `2'b01` | MEDIUM |
| `2'b10` | HIGH |
| `2'b11` | Reserved / invalid |

P1 handles codes, not frequencies. The code-to-period mapping lives entirely in
`p1_pll_behavioral`'s parameters, and the controller never sees it.

Both P1 blocks that can receive the reserved code reject it:

| Block | Behaviour on `2'b11` |
|-------|----------------------|
| `p1_pll_controller` | enters ERROR, sticky `pll_error`, no acknowledgement, PLL untouched |
| `p1_pll_transition_cost` | `cost_valid` low, all cost outputs zero |
| `p1_pll_behavioral` | `cfg_reject` high, stays unlocked, clock stopped |

In the integrated wrapper the controller rejects it first, so the model never
sees it. The top-level test confirms `cfg_reject` stays low throughout an
invalid request.

---

## 2. Clock periods

Illustrative, in `p1_pll_behavioral`. Periods are given in picoseconds because
that is the unit Cadence will report, and the simulator's precision is 1 ps.

| Code | Parameter | Value | Period | Implied frequency |
|------|-----------|-------|--------|-------------------|
| LOW | `PERIOD_LOW_PS` | 20000 | 20 ns | 50 MHz |
| MEDIUM | `PERIOD_MED_PS` | 10000 | 10 ns | 100 MHz |
| HIGH | `PERIOD_HIGH_PS` | 5000 | 5 ns | 200 MHz |

The 2:1 ratios were picked to be easy to read on a waveform, not because any
real design point suggests them.

**Each period must be an even number of picoseconds.** The model toggles on the
half period, so an odd value would land on half a picosecond and the timescale
would truncate it, giving a clock that is not the period the module claims. The
model prints an error at time zero if any period is odd or non-positive. This is
the half-cycle truncation guard.

Control clock, used only to convert settling times into cycles:

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `CLK_REF_PERIOD_PS` | 10000 | 10 ns, 100 MHz, illustrative |

`clk_ref` is a system input. P1 does not generate it and does not constrain its
frequency; `CLK_REF_PERIOD_PS` only has to match whatever the system supplies,
or the settling cycle counts will be wrong.

---

## 3. Lock and settling model

### Startup

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `STARTUP_CYCLES` | 20 | clk_ref cycles from reset release to first lock, at the LOW code |

Measured: exactly 20 cycles. `gpu_clk` produces no edge at all before that, and
no `freq_ack` is issued, because nothing was requested.

### Settling

The behavioral model counts settling in `clk_ref` cycles, taken from
`p1_pll_transition_cost` through its `settle_cycles` input. Measured from the
cycle in which the reconfiguration strobe is seen low, lock lands exactly
`settle_cycles` cycles later.

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `MIN_SETTLE_CYCLES` | 1 | floor applied to `settle_cycles`, so lock is never asserted in the same cycle the strobe is withdrawn |

A matrix entry of zero therefore still takes one cycle. Verified.

### Reconfiguration while already reconfiguring

Defined behaviour: the sequence restarts. Lock drops again, the clock stops
again, the new code is latched and the settling counter reloads from the new
matrix entry. Verified in `tb_p1_pll_behavioral` test 11 — a 30-cycle settle
interrupted after 8 cycles by a 5-cycle request completes 5 cycles later at the
second code, not the first.

### No analog content

The model has **no jitter, no phase noise, no duty-cycle distortion, no VCO
dynamics and no supply sensitivity**. `gpu_clk` is an ideal 50% square wave
whose period changes instantaneously when the clock restarts. Nothing about
phase noise or jitter in this design is physically characterized, and this model
cannot be used to claim otherwise.

---

## 4. Transition-cost matrix

`p1_pll_transition_cost` is a combinational 3x3 directed lookup. It is
synthesizable on its own — a case statement over parameters — so P3 or P4 can
instantiate it without any change to their RTL.

### Units and rounding

| Output | Unit | Definition |
|--------|------|------------|
| `settle_ps` | picoseconds | the authoritative settling figure, straight from the parameter |
| `settle_cycles` | clk_ref cycles | `ceil(settle_ps / CLK_REF_PERIOD_PS)` |
| `energy_fj` | femtojoules | 0 means not characterized |
| `cost_valid` | — | low if either index is the reserved code |

Rounding is **always ceiling**, so the cycle count never under-states the
settling time. Verified: 100001 ps over a 10000 ps control period gives 11
cycles, not 10.

### The matrix, at a 10000 ps control clock

Illustrative. `from` is the running state, `to` the target.

| from \ to | LOW | MEDIUM | HIGH |
|-----------|-----|--------|------|
| **LOW** | 0 ps / 0 cyc | 100000 ps / 10 cyc | 180000 ps / 18 cyc |
| **MEDIUM** | 80000 ps / 8 cyc | 0 ps / 0 cyc | 120000 ps / 12 cyc |
| **HIGH** | 140000 ps / 14 cyc | 90000 ps / 9 cyc | 0 ps / 0 cyc |

Energy is 0 for all nine entries: not characterized.

The matrix is **asymmetric on purpose**. Upward transitions cost more than the
matching downward ones, on the assumption that locking to a higher frequency
takes longer. That assumption is unverified and is exactly the kind of thing
Cadence characterization should confirm or overturn.

Same-state entries are zero, but they are parameters, not hard-wired — the
cost testbench instantiates a variant with a non-zero LOW to LOW cost to prove
it.

### The matrix is in the loop

`p1_pll_top` wires `current_freq_sel` to `from_sel` and `pll_freq_code` to
`to_sel`, and feeds `settle_cycles` into the behavioral model. Changing a matrix
entry changes the simulated settling time, and the top-level testbench checks
the measured transition duration against the matrix, so a wrong entry fails a
test instead of quietly shifting the timing.

`current_freq_sel` only moves when the controller reaches DONE, so during
RECONFIG and LOCK_WAIT the index pair is exactly the transition in flight.

### Interaction with Session 1's fixed parameters

Session 1 fixed `RECONFIG_CYCLES` and `LOCK_TIMEOUT` as controller parameters,
before any settling model existed. They do interact with the matrix:

```
LOCK_TIMEOUT >= settle_cycles + 5
```

Five cycles of overhead, counting from the cycle LOCK_WAIT is entered: one
before the model samples the reconfiguration strobe low, `settle_cycles` of
settling, two synchroniser flops, and one for the FSM to act on the
synchronised lock. If a matrix entry needs more than `LOCK_TIMEOUT - 5` cycles,
the controller times out and reports an error instead of completing the
transition.

> **Corrected in Session 3.** Session 2 stated this margin as `+ 4`, reasoned
> from the pipeline rather than measured. Session 3 measured the boundary
> directly, in `tb_p1_verification` test 22: with `settle_cycles = 10`, a
> `LOCK_TIMEOUT` of 14 (`settle + 4`) **times out**, and 15 (`settle + 5`)
> completes. The margin is five, not four. The warning threshold in
> `p1_pll_top` was corrected to match; no controller logic changed.

**The smallest safe fix was to change no controller RTL at all.**
`p1_pll_controller` is untouched. `p1_pll_top` carries a simulation-only check
that prints a warning on every reconfiguration where
`LOCK_TIMEOUT < settle_cycles + 5`, naming both numbers and the transition. The
alternatives — deriving `LOCK_TIMEOUT` from the matrix inside the controller, or
making the timeout dynamic — would both mean reopening verified Session 1 logic
for a problem that a parameter check catches.

With the default matrix the worst entry is 18 cycles, so `LOCK_TIMEOUT` must be
at least 23. The default is 1024, which is 44 times the requirement. Verified
three ways: the default completes every transition; a `LOCK_TIMEOUT` of 8
raises the warning and fails the transition rather than silently completing it;
and the `settle + 4` / `settle + 5` boundary above behaves exactly as the
corrected rule says.

---

## 5. Measured timing

All from XSim v2026.1, with `RECONFIG_CYCLES = 4` and the default matrix.
Every figure below is a simulation result, not an estimate.

### Transition duration

```
pll_busy high time = RECONFIG_CYCLES + settle_cycles + 4   (clk_ref cycles)
```

| Transition | settle | measured `pll_busy` |
|------------|--------|---------------------|
| LOW to MEDIUM | 10 | 18 |
| MEDIUM to HIGH | 12 | 20 |
| HIGH to LOW | 14 | 22 |
| LOW to HIGH | 18 | 26 |
| HIGH to MEDIUM | 9 | 17 |
| MEDIUM to LOW | 8 | 16 |
| any same-state | — | 1 |

A same-state request takes one cycle because it goes ACCEPT straight to DONE
without touching the PLL.

### As P3 sees it

```
pll_req high time = RECONFIG_CYCLES + settle_cycles + 6   (clk_ref cycles)
```

Two cycles more than P1's own busy time: one at the start for P1 to sample the
request, one at the end for P3 to sample `pll_done`. Measured, not assumed.

| P3 level change | measured `pll_req` high |
|-----------------|-------------------------|
| LOW to HIGH | 28 |
| HIGH to LOW | 24 |
| LOW to MEDIUM | 20 |
| MEDIUM to HIGH | 22 |

Repeating a sequence gives identical cycle counts, which is what the
shared-clock assumption buys. A genuine domain crossing would not be repeatable
to the cycle like this.

### clock_valid timing

| Event | Measured |
|-------|----------|
| `clock_valid` rises after lock, completed transition | 4 clk_ref cycles |
| `clock_valid` rises after lock, startup | 3 clk_ref cycles |
| `clock_valid` falls before the clock stops | at least 1 cycle early |
| `clock_valid` falls after an abrupt lock loss | 5 cycles, bounded at 8 |

Startup is one cycle quicker because the controller adopts the reset code from
IDLE and never passes through DONE.

### Clock waveform

Measured against a 0.01 ns tolerance; every measurement landed exactly on the
expected value.

| Code | Period | High time |
|------|--------|-----------|
| LOW | 20.000 ns | 10.000 ns |
| MEDIUM | 10.000 ns | 5.000 ns |
| HIGH | 5.000 ns | 2.500 ns |

---

## 6. Clock safety, and what the model does not prove

`clock_valid` is the signal a consumer should gate on. `pll_locked` is the raw
synchronised lock bit and is not a usability indicator.

What is actually guaranteed, and verified:

1. **`gpu_clk` never produces a rising edge while the PLL is unlocked.** Checked
   continuously in two testbenches. The model holds the clock low whenever it is
   unlocked, and each run begins with a low half period so the first rising edge
   comes half a cycle after lock rather than in the same delta.
2. **No runt pulse.** A stop request is honoured only at the end of the half
   period in progress, so `gpu_clk` always settles low.
3. **`clock_valid` falls before the clock becomes unsafe**, by at least one
   cycle. It is cleared when the controller leaves ACCEPT for RECONFIG, which is
   a cycle before the model even samples the reconfiguration strobe.
4. **`clock_valid` never rises before lock.**
5. **The period after a transition matches the target code**, measured from the
   waveform.

What is **not** true, and matters:

- **`gpu_clk` starts running about four `clk_ref` cycles before `clock_valid`
  rises.** The synchroniser and the FSM both cost cycles. This is conservative
  for a consumer of `clock_valid`, which under-claims rather than over-claims,
  but `clock_valid` is not a precise "the clock is running" indicator.
- **`gpu_clk` keeps running for up to one `clk_ref` cycle after a
  reconfiguration is requested**, at the old and still-settled frequency,
  because the model samples the strobe on `clk_ref`. Plus up to one high half
  period after that, to avoid the runt pulse.
- **`clock_valid` lags an abrupt loss of lock by several cycles** — measured at
  5. Two are the synchroniser; the rest are the controller finishing DONE, since
  loss of lock is only detected from IDLE. A real design that must react faster
  than that needs a separate asynchronous path, which P1 does not have.
- **This is not a glitch-free clock switch, and there is no clock gate.** The
  model simply stops driving the clock. There is no AND gate here, and nobody
  should read one into it: a combinational AND of a clock and an enable is not
  glitch-free, and nothing in this model demonstrates that it would be.
- **`pll_lock_in` is driven synchronously to `clk_ref` by the model**, for
  determinism. Real lock is asynchronous. The two-flop synchroniser is therefore
  exercised structurally but never for metastability, which functional
  simulation cannot do anyway.

### What an FPGA implementation would need

`p1_pll_behavioral` and `p1_pll_top` are simulation-only and must not be
synthesized. For a real build:

- An AMD MMCM or PLLE primitive instead of the behavioral model, with its
  `LOCKED` output feeding `pll_lock_in`.
- Dynamic reconfiguration through the MMCM's DRP port, or a clock multiplexer
  between several fixed MMCM outputs. Either way the controller's
  `pll_reconfig_en` / `pll_freq_code` pair has to be adapted to the primitive's
  own protocol, which is a Session 3 question.
- `BUFG` on the generated clock, and `BUFGCE` or `BUFGMUX` if the clock really
  must be gated or switched. A glitch-free switch needs the primitive, not RTL.
- Proper timing constraints: `create_clock` on `clk_ref`, a generated clock on
  the MMCM output, and `set_clock_groups` to mark the two asynchronous.
- A real metastability assessment on `LOCKED`, which the synchroniser addresses
  structurally but which simulation cannot confirm.

Only `p1_pll_controller` and `p1_pll_transition_cost` survive synthesis as they
stand.

---

## 7. Cadence calibration parameters

What a characterization run needs to produce, and where each number goes.

> The **procedure** — the CSV schema, the corner-reduction rules, the
> generator script and what to re-run afterwards — is in
> [`p1_cadence_calibration.md`](p1_cadence_calibration.md). The table below
> is the inventory of what is still a placeholder.

| Quantity | Parameter | Module | Currently |
|----------|-----------|--------|-----------|
| LOW period | `PERIOD_LOW_PS` | `p1_pll_behavioral` | 20000 ps, illustrative |
| MEDIUM period | `PERIOD_MED_PS` | `p1_pll_behavioral` | 10000 ps, illustrative |
| HIGH period | `PERIOD_HIGH_PS` | `p1_pll_behavioral` | 5000 ps, illustrative |
| Cold-start lock time | `STARTUP_CYCLES` | `p1_pll_behavioral` | 20 cycles, illustrative |
| Settling time, 9 directed entries | `SETTLE_*_PS` | `p1_pll_transition_cost` | illustrative, asymmetric |
| Transition energy, 9 entries | `ENERGY_*_FJ` | `p1_pll_transition_cost` | 0, not characterized |
| Control clock period | `CLK_REF_PERIOD_PS` | both | 10000 ps, illustrative |
| Reconfiguration strobe width | `RECONFIG_CYCLES` | `p1_pll_controller` | 4 cycles, illustrative |
| Lock timeout | `LOCK_TIMEOUT` | `p1_pll_controller` | 1024 cycles, must be >= worst settle + 5, so >= 23 with the default matrix |

Two of these are decisions, not measurements, and need the team rather than
Cadence:

- **What LOW, MEDIUM and HIGH actually mean in MHz.** This fixes the meaning of
  the shared encoding for P2 and P3 as well as P1, so it cannot be settled
  inside P1.
- **`clk_ref`'s frequency**, which every cycle count in this document depends on.

---

## 8. Interface to P3 and P4

### P3

P3 drives P1 with no change to P3's RTL:

| P3 net | P1 port |
|--------|---------|
| `clk` | `clk_ref` — must be the same net |
| `rst_n` | `rst_n` |
| `pll_req` | `freq_req` |
| `pll_freq_sel` | `freq_sel` |
| `pll_done` | `pll_done` |

Verified in `tb_p1_p3_integration` against the real `p3_dvfs_controller`:
the request and the frequency code reach P1 unchanged, `pll_done` reaches P3,
P3's `current_level` never moves before P1's `freq_ack`, and six consecutive
level changes produce exactly six acknowledgements.

The sequencing P3 owns also still holds with P1 attached: voltage before
frequency on an upshift, frequency before voltage on a downshift, and
`volt_req` and `pll_req` never asserted together.

### P4

**P4 is not connected to P1 at all.** P3 sequences P4, and P1 has no voltage
awareness. There is still no P4 or PMU specification anywhere in the repository.

If P4 wants the settling or energy figures, it instantiates
`p1_pll_transition_cost` directly. It is combinational, has no clock and no
reset, and needs nothing from the rest of P1. That is the reason it is a
separate module rather than a table inside the behavioral model.

### Clock-domain assumptions

1. `clk_ref` and P3's `clk` are the same net. Every cycle count in section 5
   depends on it.
2. `rst_n` is asynchronous and active low throughout P1, matching P3.
3. `gpu_clk` clocks nothing inside P1. The controller keeps running on `clk_ref`
   while `gpu_clk` is stopped, which is what lets it sequence its own recovery.
4. `pll_lock_in` is the only signal crossing into the control domain, and it is
   synchronised with two flops.
5. Whether `rst_n` is released synchronously with respect to `clk_ref` is still
   unanswered, carried over from P3's open items.

---

## 9. Verification results

XSim v2026.1, behavioral. **381 checks, 381 passes, 0 failures.**

| Testbench | Checks | Covers |
|-----------|--------|--------|
| `tb_p1_pll_controller` | 49 | Session 1 FSM, rerun unchanged |
| `tb_p1_pll_transition_cost` | 79 | all 9 entries, 7 reserved combinations, ceiling rounding, asymmetry, energy, partial calibration |
| `tb_p1_pll_behavioral` | 48 | startup, three periods and duty cycles, settling, reserved rejection, mid-settle restart, reset during startup and settling, repeated transitions, single-cycle strobe |
| `tb_p1_pll_top` | 148 | all six cross transitions and three same-state cases end to end, reserved rejection, error clear, asymmetry, mid-transition request change, repeated requests, reset during reconfiguration and settling, lock loss in DONE, clock stability, `RECONFIG_CYCLES = 1`, `LOCK_TIMEOUT = 0`, `LOCK_TIMEOUT` too small |
| `tb_p1_p3_integration` | 57 | real `p3_dvfs_controller` driving P1, sequencing, no premature completion, no duplicate transitions, and the known deadlock |

Run with `sh run_xsim.sh` from `P1_PLL/simulation/`. Transcripts:
[`p1_session2_sim_output.txt`](../simulation/p1_session2_sim_output.txt) for the
whole suite and
[`p1_controller_sim_output.txt`](../simulation/p1_controller_sim_output.txt) for
the Session 1 testbench alone.

Testbench conventions: inputs are driven on `negedge clk_ref`, away from the
sampling edge; the PLL stand-in in `tb_p1_pll_controller` is clocked and
level-sensitive rather than edge-triggered on the request; clock periods are
measured from the waveform with an explicit 0.01 ns tolerance rather than
inferred from the frequency code.

---

## 10. Known limitations

Design and model:

1. The behavioral model has no analog content at all — no jitter, phase noise,
   duty distortion or VCO dynamics.
2. `gpu_clk` is stopped while unlocked. A real PLL keeps producing an output
   during relock, at the wrong frequency. The model is therefore safer than
   reality, not equivalent to it.
3. No glitch-free clock switching or clock gating is modelled.
4. `pll_lock_in` is synchronous in the model; the synchroniser is never
   exercised for metastability.
5. `clock_valid` lags both the start of the clock and an abrupt loss of lock.
   Section 6 gives the measured numbers.
6. `p1_pll_behavioral` and `p1_pll_top` are not synthesizable.
7. Every frequency, period, settling time and energy figure is illustrative.

Verification:

8. No gate-level or post-implementation run. Synthesis of `p1_pll_subsystem`
   has been run for `xc7z020clg400-1` (see
   [`p1_fpga_feasibility.md`](p1_fpga_feasibility.md) section 2.1), but every
   number in this document is from behavioral simulation; none is a
   post-synthesis or routed figure, and nothing has been placed, routed or run
   on hardware.
9. `RECONFIG_CYCLES` tested at 4 and 1 only. `LOCK_TIMEOUT` tested at 1024, 8
   and 0 only. The matrix is tested at its defaults plus one calibrated variant.
10. Only one `clk_ref` period, 10 ns, is simulated. Nothing checks that
    `CLK_REF_PERIOD_PS` agrees with the actual `clk_ref`, and a mismatch would
    silently change every settling time.
11. The P3 integration does not drive P2's side of P3, so workload-driven level
    selection is out of scope here.
12. The deadlock in section 11 is reproduced and documented, not fixed.

---

## 11. The P1 / P3 deadlock

**Open. P3 to P1 integration is not complete while this stands.**

Session 1 identified this by inspection. Session 2 reproduces it in simulation,
in `tb_p1_p3_integration` test 8.

### What happens

1. P3 requests a frequency change and asserts `pll_req`, holding it until it
   sees `pll_done`. That is P3's documented protocol.
2. P1 fails the transition — the lock timeout expires. It enters ERROR, sets
   sticky `pll_error`, and issues neither `freq_ack` nor `pll_done`.
3. P1's ERROR state exits only when `freq_req` falls.
4. P3 has no error input and no timeout. It waits in FREQUENCY_CHANGE for a
   `pll_done` that will never arrive, holding `pll_req` asserted.
5. Neither side can move. Only a reset breaks it.

Verified in simulation: with `LOCK_TIMEOUT` set below what the matrix needs, P1
raises `pll_error`, P3 stays in FREQUENCY_CHANGE with `pll_req` high for at
least 300 further cycles, `current_level` is never committed, `clock_valid`
stays low, and no `freq_ack` is ever issued. Asserting `rst_n` clears both.

The test asserts that the hang occurs, so it passes while the defect is present
and will fail the day P3 gains a way out. That is deliberate: it is a regression
guard on a known defect, not a claim that the behaviour is correct.

### Why P1 cannot fix it

Every option inside P1 is worse:

- Acknowledging a failed transition would tell P3 the GPU clock is at the new
  frequency when it is not. That is the one lie that could damage hardware.
- Leaving ERROR on its own and re-accepting the still-asserted `pll_req` gives
  an unbounded retry loop at whatever rate the failure recurs.
- A watchdog inside P1 that drops `pll_done` high for one cycle to unstick P3
  is the same lie as the first option, with extra steps.

### Recommended minimal fix, for team approval

Interface-level, in rough order of preference:

1. **Add a `pll_error` input to P3**, and a transition out of FREQUENCY_CHANGE
   when it is high — back to IDLE with `current_level` unchanged. One input, one
   case branch. P1 already drives the signal. This is the smallest correct fix.
2. **Add a timeout to P3's handshake states.** No new ports, but P3 then gives
   up without knowing why, and the same gap exists for P4.
3. **Put a PMU between them** and let it own recovery, including `err_clear`.
   The cleanest long-term answer and the most work; there is no PMU
   specification yet.

Option 1 changes P3, so it is the P3 owner's call. Nothing was changed in P3 for
this session.

The same gap exists on the P4 side — P3 has no error input there either — and is
recorded as open item 5 in P3's own
[`interface_assumptions.md`](../../P3_DVFS_Controller/docs/interface_assumptions.md).
