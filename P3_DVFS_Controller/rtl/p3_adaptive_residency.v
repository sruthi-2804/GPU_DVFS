`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09.11.2026 05:46:29
// Design Name: 
// Module Name: p3_adaptive_residency
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

module p3_adaptive_residency #(
    parameter SHORT_CYCLES  = 2,
    parameter NORMAL_CYCLES = 4,
    parameter LONG_CYCLES   = 8,
    parameter COUNT_WIDTH   = 4
)(
    input wire clk,
    input wire rst_n,

    input wire transition_done,
    input wire urgent_change,
    input wire frequent_switching,

    output wire residency_done // determines whether it permits transition or not
);
reg [COUNT_WIDTH-1:0] residency_count; // how much time has passed
reg [COUNT_WIDTH-1:0] residency_limit; //the controller blocks new transitions until residency_count is met

wire [COUNT_WIDTH-1:0] selected_limit; //duration currently recommended by the adaptive policy

assign selected_limit = frequent_switching ? LONG_CYCLES : urgent_change ? SHORT_CYCLES : NORMAL_CYCLES;
assign residency_done = (residency_count >= residency_limit);
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        residency_count <= 0;
        residency_limit <= 0;
    end
    else if (transition_done) begin
        residency_count <= 0;
        residency_limit <= selected_limit;
    end
    else if (residency_count < residency_limit) begin
        residency_count <= residency_count + 1'b1;
    end
end




endmodule
