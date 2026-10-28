# P3 — Provisional interface assumptions

These are **working assumptions**, not a ratified interface specification. They
were chosen so that P3 could be designed and verified before P1 and P4 exist.
Every item here must be confirmed with the owning sub-block before integration.

Anything marked **OPEN** is an unresolved question for the team.

---

## 1. Shared performance-level encoding

| Encoding | Level |
|----------|-------|
| `2'b00` | LOW |
| `2'b01` | MEDIUM |
| `2'b10` | HIGH |
| `2'b11` | Reserved / invalid |

P3 filters `2'b11` in `IDLE` and never starts a transition for it.

**OPEN:** confirm P1, P2 and P4 use these same encodings, and agree what a
sub-block should do if it ever receives `2'b11`.

---

## 2. P4 — voltage regulator interface

### Signals

| Signal | Direction (P3 view) | Width | Meaning |
|--------|---------------------|-------|---------|
| `volt_req` | output | 1 | Voltage change requested |
| `volt_level` | output | 2 | Target voltage level |
| `volt_done` | input | 1 | Voltage has settled at `volt_level` |

### Assumed protocol

1. `volt_req` is **level-sensitive** and is held asserted for the entire
   request. It is not a single-cycle pulse.
2. `volt_level` is valid for as long as `volt_req` is asserted and does not
   change mid-request.
3. On observing `volt_req`, P4 drives `volt_done` **low** while the rail slews.
4. P4 raises `volt_done` only once the rail has **settled** at the requested
   level — not when the request is merely accepted.
5. P4 holds `volt_done` high until P3 releases `volt_req`, then returns it low.
6. Settling time is **unbounded** from P3's point of view. P3 waits in
   `VOLTAGE_CHANGE` for as long as it takes.

### How P3 relies on this

P3 does not accept `volt_done` until it has first observed it low while in
`VOLTAGE_CHANGE`. This is tracked by the sticky `volt_seen_busy` flag:

```verilog
if (state == VOLTAGE_CHANGE) begin
    if (!volt_done) volt_seen_busy <= 1'b1;
end
else volt_seen_busy <= 1'b0;
```

The state advances only on `volt_seen_busy && volt_done`. Point 3 above is what
makes this safe: if P4 did **not** drop `volt_done` on seeing a request, and it
happened to still be high from the previous transition, P3 would wait forever.

**OPEN:** confirm P4 actually deasserts `volt_done` on each new request.

---

## 3. P1 — PLL interface

### Signals

| Signal | Direction (P3 view) | Width | Meaning |
|--------|---------------------|-------|---------|
| `pll_req` | output | 1 | Frequency change requested |
| `pll_freq_sel` | output | 2 | Target frequency level |
| `pll_done` | input | 1 | PLL locked at `pll_freq_sel` |

### Assumed protocol

1. `pll_req` is **level-sensitive** and is held asserted for the entire request.
2. `pll_freq_sel` is valid for as long as `pll_req` is asserted and does not
   change mid-request.
3. On observing `pll_req`, P1 drives `pll_done` **low** while relocking.
4. P1 raises `pll_done` only once the PLL is **locked** at the requested
   frequency — not when the request is merely accepted.
5. P1 holds `pll_done` high until P3 releases `pll_req`, then returns it low.
6. Lock time is **unbounded** from P3's point of view. P3 waits in
   `FREQUENCY_CHANGE` for as long as it takes.

### How P3 relies on this

Identical to P4: the `pll_seen_busy` flag requires `pll_done` to be observed low
before it is accepted high.

**OPEN:** confirm P1 deasserts `pll_done` on each new request, and clarify
whether loss of lock during steady-state operation is signalled on this same
pin or on a separate one.

---

## 4. Clocking and reset

1. P3 is clocked by `clk` and updates state on `posedge clk`.
2. `rst_n` is **asynchronous, active-low**. On reset P3 returns to `IDLE` with
   `current_level = 2'b00`.
3. P3 samples `pll_done` and `volt_done` **directly**, with no synchroniser.

**OPEN — this is the most important one.** Assumption 3 is only safe if
`pll_done` and `volt_done` are synchronous to `clk`. A PLL lock signal in
particular is often generated in a different clock domain. If either crosses a
domain boundary, a two-flop synchroniser must be added at the P3 input, and the
metastability risk must be assessed. This has not been resolved.

**OPEN:** is `rst_n` released synchronously with respect to `clk`?

---

## 5. Error handling

P3 currently has **no timeout and no error path**. If P1 or P4 never
acknowledges, P3 waits in the corresponding handshake state indefinitely, with
its request still asserted.

**OPEN:** does the system need a timeout, and if so what should happen on
expiry? Candidate behaviours: abort and return to `IDLE` leaving
`current_level` unchanged; retry the request; or raise an error output for
software to handle. This affects the FSM and must be decided before
integration.

---

## 6. Request timing from P2

1. P2 drives `requested_level` continuously; P3 samples it in `IDLE`.
2. P3 latches the request into `target_level` on entering `DECIDE` and ignores
   further changes until the transition completes.

**OPEN:** what should happen if P2 changes `requested_level` *during* a
transition? P3 currently finishes the in-flight change and only then looks at
the new value. An alternative is to abort and re-plan. Neither behaviour has
been agreed, and the current one is not covered by any test.

---

## 7. Summary of open items

| # | Item | Blocks |
|---|------|--------|
| 1 | Shared `2'b11` handling | P1, P2, P4 |
| 2 | P4 deasserts `volt_done` per request | P4 |
| 3 | P1 deasserts `pll_done` per request; loss-of-lock signalling | P1 |
| 4 | Clock domain of `pll_done` / `volt_done`; synchroniser needed? | P1, P4 |
| 5 | Timeout / error behaviour | all |
| 6 | Request change mid-transition | P2 |
