`timescale 1ns / 1ps

// P1 top-level wrapper.
//
// SIMULATION ONLY, because it instantiates p1_pll_behavioral. The synthesizable
// part of P1 is p1_pll_controller alone. For an FPGA build, replace
// p1_pll_behavioral with a supported PLL/MMCM primitive plus clock buffering,
// keep p1_pll_controller unchanged, and keep p1_pll_transition_cost if the
// settling numbers are wanted in hardware.
//
// Structure:
//   p1_pll_controller      request handshake and FSM, clocked by clk_ref
//   p1_pll_transition_cost directed cost lookup, from current_freq_sel to
//                          pll_freq_code
//   p1_pll_behavioral      lock model and gpu_clk generation
//
// The cost matrix sits in the loop: it tells the behavioral model how many
// clk_ref cycles this particular transition takes to settle. Changing a matrix
// entry changes the simulated settling time, it is not a table nobody reads.
//
// Wiring to the rest of the project:
//   P3 drives freq_req from its pll_req, freq_sel from its pll_freq_sel, and
//   samples pll_done. P3's clk and this module's clk_ref must be the same net.
//   P4 is not connected to P1 at all; it is sequenced by P3. P4 can instantiate
//   p1_pll_transition_cost on its own if it needs the settling or energy
//   figures, with no change to P1.
//
// The controller runs on clk_ref throughout, including while gpu_clk is stopped.
// gpu_clk never clocks anything inside this wrapper.

module p1_pll_top #(
    // Controller timing
    parameter integer RECONFIG_CYCLES = 4,
    parameter integer LOCK_TIMEOUT = 1024,

    // Control clock period, illustrative, used to convert settling time
    parameter integer CLK_REF_PERIOD_PS = 10000,

    // Illustrative GPU clock periods, in picoseconds
    parameter integer PERIOD_LOW_PS = 20000,
    parameter integer PERIOD_MED_PS = 10000,
    parameter integer PERIOD_HIGH_PS = 5000,

    // Behavioral model timing
    parameter integer STARTUP_CYCLES = 20,
    parameter integer MIN_SETTLE_CYCLES = 1,

    // Transition-cost matrix, in picoseconds. Illustrative and asymmetric.
    parameter integer SETTLE_LOW_LOW_PS = 0,
    parameter integer SETTLE_LOW_MED_PS = 100000,
    parameter integer SETTLE_LOW_HIGH_PS = 180000,
    parameter integer SETTLE_MED_LOW_PS = 80000,
    parameter integer SETTLE_MED_MED_PS = 0,
    parameter integer SETTLE_MED_HIGH_PS = 120000,
    parameter integer SETTLE_HIGH_LOW_PS = 140000,
    parameter integer SETTLE_HIGH_MED_PS = 90000,
    parameter integer SETTLE_HIGH_HIGH_PS = 0
)(
    // Control domain
    input wire clk_ref,
    input wire rst_n,

    // Frequency request, from P3
    input wire freq_req,
    input wire [1:0] freq_sel,

    // Sticky error clear, from PMU or software
    input wire err_clear,

    // Handshake and status, to P3 and the PMU
    output wire pll_done,
    output wire freq_ack,
    output wire pll_busy,
    output wire pll_error,
    output wire pll_locked,
    output wire [1:0] current_freq_sel,
    output wire clock_valid,

    // Generated GPU clock
    output wire gpu_clk
);

    // Controller to PLL model
    wire pll_reconfig_en;
    wire [1:0] pll_freq_code;
    wire pll_lock_in;

    // Cost lookup outputs
    wire [31:0] settle_ps;
    wire [15:0] settle_cycles;
    wire [31:0] energy_fj;
    wire cost_valid;

    // Model status, observed by the testbenches
    wire cfg_reject;

    p1_pll_controller #(
        .RECONFIG_CYCLES(RECONFIG_CYCLES),
        .LOCK_TIMEOUT(LOCK_TIMEOUT)
    ) u_ctrl (
        .clk_ref(clk_ref),
        .rst_n(rst_n),
        .freq_req(freq_req),
        .freq_sel(freq_sel),
        .err_clear(err_clear),
        .freq_ack(freq_ack),
        .pll_done(pll_done),
        .pll_busy(pll_busy),
        .pll_error(pll_error),
        .pll_locked(pll_locked),
        .current_freq_sel(current_freq_sel),
        .clock_valid(clock_valid),
        .pll_reconfig_en(pll_reconfig_en),
        .pll_freq_code(pll_freq_code),
        .pll_lock_in(pll_lock_in)
    );

    // from_sel is the running state, to_sel the code being programmed.
    // current_freq_sel only moves when the controller reaches DONE, so during
    // RECONFIG and LOCK_WAIT this pair is exactly the transition in flight.
    p1_pll_transition_cost #(
        .CLK_REF_PERIOD_PS(CLK_REF_PERIOD_PS),
        .SETTLE_LOW_LOW_PS(SETTLE_LOW_LOW_PS),
        .SETTLE_LOW_MED_PS(SETTLE_LOW_MED_PS),
        .SETTLE_LOW_HIGH_PS(SETTLE_LOW_HIGH_PS),
        .SETTLE_MED_LOW_PS(SETTLE_MED_LOW_PS),
        .SETTLE_MED_MED_PS(SETTLE_MED_MED_PS),
        .SETTLE_MED_HIGH_PS(SETTLE_MED_HIGH_PS),
        .SETTLE_HIGH_LOW_PS(SETTLE_HIGH_LOW_PS),
        .SETTLE_HIGH_MED_PS(SETTLE_HIGH_MED_PS),
        .SETTLE_HIGH_HIGH_PS(SETTLE_HIGH_HIGH_PS)
    ) u_cost (
        .from_sel(current_freq_sel),
        .to_sel(pll_freq_code),
        .settle_ps(settle_ps),
        .settle_cycles(settle_cycles),
        .energy_fj(energy_fj),
        .cost_valid(cost_valid)
    );

    p1_pll_behavioral #(
        .PERIOD_LOW_PS(PERIOD_LOW_PS),
        .PERIOD_MED_PS(PERIOD_MED_PS),
        .PERIOD_HIGH_PS(PERIOD_HIGH_PS),
        .STARTUP_CYCLES(STARTUP_CYCLES),
        .MIN_SETTLE_CYCLES(MIN_SETTLE_CYCLES)
    ) u_pll (
        .clk_ref(clk_ref),
        .rst_n(rst_n),
        .pll_reconfig_en(pll_reconfig_en),
        .pll_freq_code(pll_freq_code),
        .settle_cycles(settle_cycles),
        .pll_lock_in(pll_lock_in),
        .gpu_clk(gpu_clk),
        .cfg_reject(cfg_reject)
    );

    // Simulation-only compatibility check between the matrix and the
    // controller's fixed LOCK_TIMEOUT.
    //
    // Counting from LOCK_WAIT entry: one cycle before the model samples the
    // strobe low, settle_cycles of settling, 2 synchroniser cycles and 1 cycle
    // for the FSM to act on lock_sync. The controller times out once
    // wait_count reaches LOCK_TIMEOUT - 1, so a transition completes only if
    //     LOCK_TIMEOUT >= settle_cycles + 5.
    // Session 2 wrote + 4 here. Session 3 measured the boundary directly in
    // tb_p1_verification test 22: with settle_cycles = 10, a LOCK_TIMEOUT of
    // 14 times out and 15 completes. The threshold below is the corrected one.
    //
    // Total pll_busy time for a real change is unaffected and remains
    // RECONFIG_CYCLES + settle_cycles + 4 control cycles.
    always @(posedge pll_reconfig_en) begin
        if (rst_n === 1'b1 && LOCK_TIMEOUT != 0 &&
            LOCK_TIMEOUT < (settle_cycles + 5)) begin
            $display("WARNING: LOCK_TIMEOUT = %0d cannot cover settle_cycles = %0d for %b -> %b at %0t",
                     LOCK_TIMEOUT, settle_cycles, current_freq_sel,
                     pll_freq_code, $time);
        end
        if (rst_n === 1'b1 && cost_valid !== 1'b1) begin
            $display("WARNING: transition %b -> %b has no cost entry at %0t",
                     current_freq_sel, pll_freq_code, $time);
        end
    end

endmodule
