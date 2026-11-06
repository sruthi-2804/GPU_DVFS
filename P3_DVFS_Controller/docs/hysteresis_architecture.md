# P3 — Provisional hysteresis architecture

> **Status: thresholds still proposed. Level-selection RTL now exists.**
> `rtl/p3_hysteresis_controller.v` implements the level-selection table in
> section 3 as combinational logic and passes 17 of 17 directed checks in
> behavioral simulation — see
> [`waveforms/README.md`](waveforms/README.md) section 2. It is a **standalone
> module**: it is not wired to the controller FSM or to the persistence
> counter, and no integrated simulation has been run.
>
> Every threshold below is still a **proposed P3 design parameter**, chosen by
> the P3 owner as a starting point. None has been validated against a workload,
> and none has been agreed with the P2 owner. They are currently hard-coded in
> the RTL rather than exposed as module parameters.

---

## 1. Purpose

The persistence counter (see [`../README.md`](../README.md) section 7) filters
*classification* noise — it requires a class to repeat for several epochs before
it is accepted. Hysteresis addresses a different problem: a utilization figure
sitting near a single switching threshold would otherwise cause the GPU to
oscillate between performance levels even when the classification is perfectly
stable.

Hysteresis solves this by making the up-threshold and the down-threshold
*different*, so the level that triggers an upshift is well above the level that
triggers the matching downshift. The gap between them is the dead band.

---

## 2. Performance levels

Unchanged from the controller, and shared across the project:

| Encoding | Level |
|----------|-------|
| `2'b00` | LOW |
| `2'b01` | MEDIUM |
| `2'b10` | HIGH |
| `2'b11` | Reserved / invalid |

---

## 3. Proposed utilization thresholds

Utilization is expressed as a percentage of the monitoring epoch during which
the GPU was busy.

| From | To | Condition | Direction |
|------|----|-----------|-----------|
| LOW | MEDIUM | utilization ≥ **40%** | up |
| MEDIUM | LOW | utilization ≤ **25%** | down |
| MEDIUM | HIGH | utilization ≥ **75%** | up |
| HIGH | MEDIUM | utilization ≤ **55%** | down |
| LOW | HIGH | utilization ≥ **85%** | up, direct |
| HIGH | LOW | utilization ≤ **15%** | down, direct |

Resulting dead bands:

| Boundary | Up | Down | Dead band |
|----------|----|------|-----------|
| LOW / MEDIUM | 40% | 25% | 15 points |
| MEDIUM / HIGH | 75% | 55% | 20 points |
| LOW / HIGH | 85% | 15% | 70 points |

All six values are **proposed P3 design parameters**. They should be exposed as
module parameters rather than hard-coded, so they can be retuned without an RTL
change once real workload data exists.

---

## 4. Direct LOW ↔ HIGH transitions

Direct transitions between LOW and HIGH are **permitted**, skipping MEDIUM, when
utilization is extreme enough (≥ 85% or ≤ 15%). This lets the GPU respond to a
sudden load change in one step instead of two, at the cost of a larger voltage
and frequency step.

Direct transitions are **not mandatory and not the normal case**. They apply
only when their own thresholds are met; every other level change moves between
adjacent levels through MEDIUM in the usual way.

**Open — rule precedence.** The direct and single-step conditions overlap. At
10% utilization in HIGH, both *HIGH → LOW* (≤ 15%) and *HIGH → MEDIUM* (≤ 55%)
are satisfied. The proposed resolution is to **evaluate the direct condition
first and prefer the larger jump**, so 10% goes straight to LOW. The current RTL
implements that ordering, and the directed test at util = 10 in HIGH confirms
it, but the rule itself is still **undecided** and not agreed.

---

## 5. Interaction with the DVFS controller FSM

Hysteresis decides **which level to request**. It does not change **how** the
transition is carried out. The existing FSM remains solely responsible for
sequencing, and its safety ordering is unchanged:

- **Upshift** (LOW → MEDIUM, MEDIUM → HIGH, LOW → HIGH): voltage first, then
  frequency.
- **Downshift** (HIGH → MEDIUM, MEDIUM → LOW, HIGH → LOW): frequency first,
  then voltage.

A direct LOW ↔ HIGH transition is still a single FSM transaction and follows the
same ordering rule — it is not decomposed into two steps. See
[`../README.md`](../README.md) section 4.

The hysteresis layer must therefore sit **upstream** of the controller, driving
`requested_level`, and must not issue a new request while a transition is in
flight. How that back-pressure is signalled is unresolved — see item 6 in
[`interface_assumptions.md`](interface_assumptions.md), which records the same
open question for P2.

---

## 6. Epoch length

| Parameter | Proposed value | Source |
|-----------|----------------|--------|
| `EPOCH_LENGTH` | **1,000 monitoring clock cycles** | P2 RTL default, as previously shared |

**Pending confirmation from P2.** This value was taken from the P2 RTL default
and has not been confirmed as final. It matters to P3 because the epoch length,
multiplied by the persistence threshold, sets the controller's total reaction
latency: at a persistence threshold of 3, a sustained load change takes roughly
3,000 monitoring cycles to reach the FSM, before any voltage or PLL settling
time.

---

## 7. Relationship to the persistence counter

Both mechanisms damp oscillation, but on different axes — persistence in
**time**, hysteresis in **utilization**. They are intended to compose:
hysteresis maps a utilization figure to a candidate level, and persistence
requires that candidate to repeat before the FSM acts on it.

**Open:** whether both are needed, and in which order they should be applied. If
the dead bands prove wide enough, the persistence threshold could be reduced to
cut reaction latency. No analysis has been done.

---

## 8. Open items

| # | Item | Status | Owner |
|---|------|--------|-------|
| 1 | All six utilization thresholds | Proposed by P3, not validated | P3 |
| 2 | `EPOCH_LENGTH = 1000` | Pending confirmation | P2 |
| 3 | Numerical format of the utilization output (width, fixed-point or percentage integer) | Pending confirmation | P2 |
| 4 | Valid-signal timing for the utilization output | Pending confirmation | P2 |
| 5 | Final P2 to P3 interface | Pending confirmation | P2, P3 |
| 6 | Direct-transition rule precedence (section 4) | Implemented as proposed; rule still undecided | P3 |
| 7 | Whether hysteresis and persistence are both required (section 7) | Open | P3 |
| 8 | Back-pressure while an FSM transition is in flight | Open | P2, P3 |

The level-selection table in section 3 is implemented and verified standalone.
Everything else above — the threshold values themselves, the composition with
persistence, the back-pressure and the P2 interface — remains open. This
document records intent, not agreement.
