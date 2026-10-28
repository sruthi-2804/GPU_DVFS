# GPU_DVFS

Dynamic Voltage and Frequency Scaling (DVFS) for a GPU, implemented in Verilog.

The design is split into four sub-blocks, each developed on its own branch and
merged into `main` once reviewed.

## Sub-blocks

| Block | Directory | Responsibility | Branch | Status |
|-------|-----------|----------------|--------|--------|
| P1 | `P1_PLL/` | PLL / clock generation. Accepts a frequency request, reports lock. | `p1-pll` | not yet started |
| P2 | `P2_Workload_Monitor/` | Monitors workload, requests a performance level. | `p2-workload-monitor` | not yet started |
| P3 | `P3_DVFS_Controller/` | DVFS controller FSM. Sequences voltage and frequency changes safely. | `p3-dvfs-controller` | RTL complete, behavioral simulation passing directed tests |
| P4 | `P4_Voltage_Control/` | Voltage regulator control. Accepts a level request, reports settled. | `p4-voltage-control` | not yet started |

## System overview

```
        requested_level
P2 ----------------------> P3 (DVFS controller)
                            |  volt_req / volt_level
                            +----------------------> P4 (voltage regulator)
                            |  <---- volt_done
                            |
                            |  pll_req / pll_freq_sel
                            +----------------------> P1 (PLL)
                               <---- pll_done
```

P3 holds the sequencing policy. It never changes voltage and frequency at the
same time, and it orders the two steps according to the direction of the
change — see `P3_DVFS_Controller/README.md`.

## Performance levels

| Encoding | Level |
|----------|-------|
| `2'b00` | LOW |
| `2'b01` | MEDIUM |
| `2'b10` | HIGH |
| `2'b11` | Reserved / invalid |

These encodings are shared by all four sub-blocks and must not be changed
without agreement across the team.

## Working agreement

- Each sub-block is developed on its own branch, named in the table above.
- Do not push directly to `main`. Open a pull request from your sub-block
  branch and have another team member review it.
- Commit Verilog sources, documentation and selected waveform screenshots only.
  Vivado project files, simulation databases, logs and build output are
  excluded by the root `.gitignore`.
- Interface assumptions between sub-blocks are recorded in each block's
  `docs/` directory and must be reconciled before integration.

## Tools

| Item | Version |
|------|---------|
| AMD Vivado Design Suite | 2026.1 |
| AMD Vivado Simulator (XSim) | 2026.1 |
| Language | Verilog-2001 |
