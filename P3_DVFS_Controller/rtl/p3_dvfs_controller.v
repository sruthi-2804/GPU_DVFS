`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 28.10.2026 19:35:14
// Design Name: 
// Module Name: p3_dvfs_controller
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module p3_dvfs_controller (
    input wire clk,
    input wire rst_n,

    // P2 workload input
    input wire [1:0] requested_level,

    // P1 PLL acknowledgement
    input wire pll_done,

    // P4 voltage acknowledgement
    input wire volt_done,

    // P1 PLL control outputs
    output reg pll_req,
    output reg [1:0] pll_freq_sel,

    // P4 voltage control outputs
    output reg volt_req,
    output reg [1:0] volt_level,

    // Last completed performance level
    output reg [1:0] current_level
);

    // FSM state encoding
    localparam [2:0]
        IDLE             = 3'd0,
        DECIDE           = 3'd1,
        VOLTAGE_CHANGE   = 3'd2,
        FREQUENCY_CHANGE = 3'd3,
        COMPLETE         = 3'd4;

    reg [2:0] state;
    reg [2:0] next_state;

    reg [1:0] target_level;

    // Track that each request has seen done = 0
    reg volt_seen_busy;
    reg pll_seen_busy;

    // Sequential state and register logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= IDLE;
            current_level  <= 2'b00;
            target_level   <= 2'b00;
            volt_seen_busy <= 1'b0;
            pll_seen_busy  <= 1'b0;
        end
        else begin
            state <= next_state;

            // Latch a valid new workload request
            if (state == IDLE &&
                requested_level != current_level &&
                requested_level != 2'b11) begin
                target_level <= requested_level;
            end

            // Remember acknowledgement went low
            if (state == VOLTAGE_CHANGE) begin
                if (!volt_done)
                    volt_seen_busy <= 1'b1;
            end
            else begin
                volt_seen_busy <= 1'b0;
            end

            if (state == FREQUENCY_CHANGE) begin
                if (!pll_done)
                    pll_seen_busy <= 1'b1;
            end
            else begin
                pll_seen_busy <= 1'b0;
            end

            // Commit completed performance level
            if (state == COMPLETE)
                current_level <= target_level;
        end
    end

    // Combinational next-state logic
    always @(*) begin
        next_state = state;

        case (state)

            IDLE: begin
                if (requested_level != current_level &&
                    requested_level != 2'b11)
                    next_state = DECIDE;
            end

            DECIDE: begin
                if (target_level > current_level)
                    next_state = VOLTAGE_CHANGE;
                else if (target_level < current_level)
                    next_state = FREQUENCY_CHANGE;
                else
                    next_state = IDLE;
            end

            VOLTAGE_CHANGE: begin
                if (volt_seen_busy && volt_done) begin
                    if (target_level > current_level)
                        next_state = FREQUENCY_CHANGE;
                    else
                        next_state = COMPLETE;
                end
            end

            FREQUENCY_CHANGE: begin
                if (pll_seen_busy && pll_done) begin
                    if (target_level < current_level)
                        next_state = VOLTAGE_CHANGE;
                    else
                        next_state = COMPLETE;
                end
            end

            COMPLETE: begin
                next_state = IDLE;
            end

            default: begin
                next_state = IDLE;
            end

        endcase
    end

    // Combinational control outputs
    always @(*) begin
        pll_req      = 1'b0;
        pll_freq_sel = target_level;

        volt_req     = 1'b0;
        volt_level   = target_level;

        case (state)
            VOLTAGE_CHANGE: begin
                volt_req = 1'b1;
            end

            FREQUENCY_CHANGE: begin
                pll_req = 1'b1;
            end

            default: begin
                pll_req  = 1'b0;
                volt_req = 1'b0;
            end
        endcase
    end

endmodule

