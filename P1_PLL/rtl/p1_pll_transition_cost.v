`timescale 1ns / 1ps

// P1 directed transition-cost matrix.
//
// A combinational 3x3 lookup giving the modelled cost of moving from one
// frequency state to another. Synthesizable: it is a plain case statement over
// parameters, so P3 or P4 can instantiate it directly without any change to
// their own RTL.
//
// Units, fixed by this module:
//   settle_ps     picoseconds, the modelled settling duration
//   settle_cycles clk_ref cycles, ceil(settle_ps / CLK_REF_PERIOD_PS)
//   energy_fj     femtojoules, 0 meaning "not characterized"
//
// Rounding is always ceiling, so the cycle count never under-states the
// settling time. settle_ps is the authoritative figure; settle_cycles is what
// the behavioral model actually counts.
//
// Every number below is ILLUSTRATIVE. None of it is measured Cadence data.
// The settling values are deliberately asymmetric, on the assumption that
// locking upward takes longer than locking downward, but that assumption is
// itself unverified. Replace all of them with characterization results.

module p1_pll_transition_cost #(
    // Control-clock period, needed to convert settling time into cycles.
    parameter integer CLK_REF_PERIOD_PS = 10000,

    // Modelled settling duration per directed transition, in picoseconds.
    parameter integer SETTLE_LOW_LOW_PS   = 0,
    parameter integer SETTLE_LOW_MED_PS   = 100000,
    parameter integer SETTLE_LOW_HIGH_PS  = 180000,
    parameter integer SETTLE_MED_LOW_PS   = 80000,
    parameter integer SETTLE_MED_MED_PS   = 0,
    parameter integer SETTLE_MED_HIGH_PS  = 120000,
    parameter integer SETTLE_HIGH_LOW_PS  = 140000,
    parameter integer SETTLE_HIGH_MED_PS  = 90000,
    parameter integer SETTLE_HIGH_HIGH_PS = 0,

    // Optional transition energy, in femtojoules. 0 means not characterized.
    parameter integer ENERGY_LOW_LOW_FJ   = 0,
    parameter integer ENERGY_LOW_MED_FJ   = 0,
    parameter integer ENERGY_LOW_HIGH_FJ  = 0,
    parameter integer ENERGY_MED_LOW_FJ   = 0,
    parameter integer ENERGY_MED_MED_FJ   = 0,
    parameter integer ENERGY_MED_HIGH_FJ  = 0,
    parameter integer ENERGY_HIGH_LOW_FJ  = 0,
    parameter integer ENERGY_HIGH_MED_FJ  = 0,
    parameter integer ENERGY_HIGH_HIGH_FJ = 0
)(
    input wire [1:0] from_sel,
    input wire [1:0] to_sel,

    output reg [31:0] settle_ps,
    output reg [15:0] settle_cycles,
    output reg [31:0] energy_fj,
    output reg cost_valid
);

    // Settling time in whole clk_ref cycles, rounded up
    localparam integer CYC_LOW_LOW =
        (SETTLE_LOW_LOW_PS + CLK_REF_PERIOD_PS - 1) / CLK_REF_PERIOD_PS;
    localparam integer CYC_LOW_MED =
        (SETTLE_LOW_MED_PS + CLK_REF_PERIOD_PS - 1) / CLK_REF_PERIOD_PS;
    localparam integer CYC_LOW_HIGH =
        (SETTLE_LOW_HIGH_PS + CLK_REF_PERIOD_PS - 1) / CLK_REF_PERIOD_PS;
    localparam integer CYC_MED_LOW =
        (SETTLE_MED_LOW_PS + CLK_REF_PERIOD_PS - 1) / CLK_REF_PERIOD_PS;
    localparam integer CYC_MED_MED =
        (SETTLE_MED_MED_PS + CLK_REF_PERIOD_PS - 1) / CLK_REF_PERIOD_PS;
    localparam integer CYC_MED_HIGH =
        (SETTLE_MED_HIGH_PS + CLK_REF_PERIOD_PS - 1) / CLK_REF_PERIOD_PS;
    localparam integer CYC_HIGH_LOW =
        (SETTLE_HIGH_LOW_PS + CLK_REF_PERIOD_PS - 1) / CLK_REF_PERIOD_PS;
    localparam integer CYC_HIGH_MED =
        (SETTLE_HIGH_MED_PS + CLK_REF_PERIOD_PS - 1) / CLK_REF_PERIOD_PS;
    localparam integer CYC_HIGH_HIGH =
        (SETTLE_HIGH_HIGH_PS + CLK_REF_PERIOD_PS - 1) / CLK_REF_PERIOD_PS;

    // Directed lookup. from_sel is the running state, to_sel the target.
    // A reserved code on either index makes the entry invalid.
    always @(*) begin
        cost_valid = 1'b1;

        case ({from_sel, to_sel})

            4'b0000: begin                      // LOW -> LOW
                settle_ps     = SETTLE_LOW_LOW_PS;
                settle_cycles = CYC_LOW_LOW;
                energy_fj     = ENERGY_LOW_LOW_FJ;
            end

            4'b0001: begin                      // LOW -> MEDIUM
                settle_ps     = SETTLE_LOW_MED_PS;
                settle_cycles = CYC_LOW_MED;
                energy_fj     = ENERGY_LOW_MED_FJ;
            end

            4'b0010: begin                      // LOW -> HIGH
                settle_ps     = SETTLE_LOW_HIGH_PS;
                settle_cycles = CYC_LOW_HIGH;
                energy_fj     = ENERGY_LOW_HIGH_FJ;
            end

            4'b0100: begin                      // MEDIUM -> LOW
                settle_ps     = SETTLE_MED_LOW_PS;
                settle_cycles = CYC_MED_LOW;
                energy_fj     = ENERGY_MED_LOW_FJ;
            end

            4'b0101: begin                      // MEDIUM -> MEDIUM
                settle_ps     = SETTLE_MED_MED_PS;
                settle_cycles = CYC_MED_MED;
                energy_fj     = ENERGY_MED_MED_FJ;
            end

            4'b0110: begin                      // MEDIUM -> HIGH
                settle_ps     = SETTLE_MED_HIGH_PS;
                settle_cycles = CYC_MED_HIGH;
                energy_fj     = ENERGY_MED_HIGH_FJ;
            end

            4'b1000: begin                      // HIGH -> LOW
                settle_ps     = SETTLE_HIGH_LOW_PS;
                settle_cycles = CYC_HIGH_LOW;
                energy_fj     = ENERGY_HIGH_LOW_FJ;
            end

            4'b1001: begin                      // HIGH -> MEDIUM
                settle_ps     = SETTLE_HIGH_MED_PS;
                settle_cycles = CYC_HIGH_MED;
                energy_fj     = ENERGY_HIGH_MED_FJ;
            end

            4'b1010: begin                      // HIGH -> HIGH
                settle_ps     = SETTLE_HIGH_HIGH_PS;
                settle_cycles = CYC_HIGH_HIGH;
                energy_fj     = ENERGY_HIGH_HIGH_FJ;
            end

            default: begin                      // reserved code on either side
                settle_ps     = 32'd0;
                settle_cycles = 16'd0;
                energy_fj     = 32'd0;
                cost_valid    = 1'b0;
            end

        endcase
    end

endmodule
