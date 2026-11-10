`timescale 1ns / 1ps

// P1 behavioral PLL and GPU clock model.
//
// SIMULATION ONLY. THIS MODULE IS NOT SYNTHESIZABLE AND MUST NOT BE SYNTHESIZED.
// It generates gpu_clk with explicit # delays, which have no hardware meaning.
// On a real device this block is replaced by a supported PLL/MMCM primitive
// with proper clock buffering; p1_pll_controller is the part that survives
// synthesis.
//
// What it models:
//   - a startup lock sequence after reset, at the LOW code
//   - loss of lock while pll_reconfig_en is asserted
//   - a settling interval, in clk_ref cycles, taken from the transition-cost
//     matrix via settle_cycles
//   - relock, then a clean restart of gpu_clk at the new period
//
// What it does NOT model: jitter, phase noise, duty-cycle distortion, VCO
// behaviour, supply sensitivity, or anything else analog. The output is an
// ideal 50% square wave whose period changes instantaneously at restart.
// Nothing here is physically characterized.

module p1_pll_behavioral #(
    // Illustrative clock periods, in picoseconds. Not approved project values.
    // Each must be even so the half period lands on a whole picosecond.
    parameter integer PERIOD_LOW_PS  = 20000,
    parameter integer PERIOD_MED_PS  = 10000,
    parameter integer PERIOD_HIGH_PS = 5000,

    // clk_ref cycles from reset release to first lock at the LOW code.
    parameter integer STARTUP_CYCLES = 20,

    // Floor applied to settle_cycles, so lock is never asserted in the same
    // cycle the reconfiguration strobe is withdrawn.
    parameter integer MIN_SETTLE_CYCLES = 1
)(
    // Reference clock, used only to count the settling interval
    input wire clk_ref,
    input wire rst_n,

    // Reconfiguration request from p1_pll_controller
    input wire pll_reconfig_en,
    input wire [1:0] pll_freq_code,

    // Settling duration for this transition, from p1_pll_transition_cost
    input wire [15:0] settle_cycles,

    // Back to the controller
    output reg pll_lock_in,

    // Generated GPU clock
    output reg gpu_clk,

    // Latched code was the reserved encoding, so the model stays unlocked
    output reg cfg_reject
);

    localparam [1:0]
        CODE_LOW     = 2'b00,
        CODE_MEDIUM  = 2'b01,
        CODE_HIGH    = 2'b10,
        CODE_INVALID = 2'b11;

    // Code the model is currently configured for
    reg [1:0] code_r;

    // Settling countdown and its previous-strobe companion
    reg [15:0] cnt;
    reg settling;
    reg reconfig_q;

    // gpu_clk is generated only while this is high
    reg clk_run;

    // Settling length actually used, after the floor is applied
    wire [15:0] settle_load =
        (settle_cycles < MIN_SETTLE_CYCLES) ? MIN_SETTLE_CYCLES : settle_cycles;

    // Half period for the configured code, in nanoseconds
    real half_ns;

    always @(*) begin
        case (code_r)
            CODE_LOW:    half_ns = PERIOD_LOW_PS  / 2000.0;
            CODE_MEDIUM: half_ns = PERIOD_MED_PS  / 2000.0;
            CODE_HIGH:   half_ns = PERIOD_HIGH_PS / 2000.0;
            default:     half_ns = PERIOD_LOW_PS  / 2000.0;
        endcase
    end

    // Lock and settling model. Everything here is counted on clk_ref, so a
    // reconfiguration arriving mid-settle simply reloads the counter.
    always @(posedge clk_ref or negedge rst_n) begin
        if (!rst_n) begin
            pll_lock_in <= 1'b0;
            clk_run     <= 1'b0;
            code_r      <= CODE_LOW;
            cnt         <= STARTUP_CYCLES;
            settling    <= 1'b1;
            reconfig_q  <= 1'b0;
            cfg_reject  <= 1'b0;
        end
        else begin
            reconfig_q <= pll_reconfig_en;

            if (pll_reconfig_en) begin
                // Configuration is being written. Lose lock, stop the clock
                // and take the new code. A request arriving while already
                // settling lands here too, which restarts the whole sequence.
                pll_lock_in <= 1'b0;
                clk_run     <= 1'b0;
                settling    <= 1'b0;
                cnt         <= 16'd0;
                code_r      <= pll_freq_code;
                cfg_reject  <= (pll_freq_code == CODE_INVALID);
            end
            else if (reconfig_q) begin
                // Strobe just fell, so the code is committed. Start settling,
                // unless the code is the reserved encoding.
                //
                // The load is settle_load - 1 because this edge is itself the
                // first cycle of the interval. Measured from here, lock lands
                // exactly settle_load cycles later, which is the same
                // convention the startup countdown uses.
                if (code_r == CODE_INVALID) begin
                    settling <= 1'b0;
                end
                else if (settle_load <= 16'd1) begin
                    settling    <= 1'b0;
                    pll_lock_in <= 1'b1;
                    clk_run     <= 1'b1;
                end
                else begin
                    settling <= 1'b1;
                    cnt      <= settle_load - 16'd1;
                end
            end
            else if (settling) begin
                if (cnt <= 16'd1) begin
                    settling    <= 1'b0;
                    pll_lock_in <= 1'b1;
                    clk_run     <= 1'b1;
                end
                else begin
                    cnt <= cnt - 16'd1;
                end
            end
        end
    end

    // Simulation-only clock generation.
    //
    // gpu_clk is held low whenever the model is unlocked, so no edge at the new
    // period can appear before lock.
    //
    // Each run begins with a low half period, so the first rising edge comes
    // half a cycle after lock rather than in the same delta as it. That keeps
    // "no rising edge while unlocked" a strict property instead of a race.
    //
    // A stop request is honoured at the end of whichever half period is in
    // progress, so gpu_clk always settles low and never emits a shortened
    // pulse. The cost is at most one high half period of the old, already
    // settled frequency. Truncating that phase instead would produce a runt
    // pulse, which is the worse of the two.
    initial begin
        gpu_clk = 1'b0;
    end

    always begin
        if (clk_run === 1'b1) begin
            gpu_clk = 1'b0;
            #(half_ns);
            if (clk_run === 1'b1) begin
                gpu_clk = 1'b1;
                #(half_ns);
            end
        end
        else begin
            gpu_clk = 1'b0;
            @(clk_run);
        end
    end

    // Parameter sanity. An odd period would put the half period on a half
    // picosecond and the timescale would truncate it, so the generated clock
    // would not have the period this module claims.
    initial begin
        if (PERIOD_LOW_PS <= 0 || PERIOD_MED_PS <= 0 || PERIOD_HIGH_PS <= 0)
            $display("ERROR: p1_pll_behavioral period parameters must be > 0");
        if ((PERIOD_LOW_PS % 2) != 0)
            $display("ERROR: PERIOD_LOW_PS = %0d is odd, half period truncates",
                     PERIOD_LOW_PS);
        if ((PERIOD_MED_PS % 2) != 0)
            $display("ERROR: PERIOD_MED_PS = %0d is odd, half period truncates",
                     PERIOD_MED_PS);
        if ((PERIOD_HIGH_PS % 2) != 0)
            $display("ERROR: PERIOD_HIGH_PS = %0d is odd, half period truncates",
                     PERIOD_HIGH_PS);
        if (STARTUP_CYCLES < 1)
            $display("ERROR: STARTUP_CYCLES must be >= 1");
        if (MIN_SETTLE_CYCLES < 1)
            $display("ERROR: MIN_SETTLE_CYCLES must be >= 1");
    end

endmodule
