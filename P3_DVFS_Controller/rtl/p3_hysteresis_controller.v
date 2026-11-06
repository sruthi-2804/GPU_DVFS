`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06.11.2026 11:54:59
// Design Name: 
// Module Name: p3_hysteresis_controller
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


module p3_hysteresis_controller (
    input wire [7:0] gpu_utilization,
    input wire utilization_valid,
    input wire [1:0] current_level,

    output reg [1:0] recommended_level
);
    localparam LOW    = 2'b00;
    localparam MEDIUM = 2'b01;
    localparam HIGH   = 2'b10;
    
 always @(*) begin
    recommended_level = current_level;

    if (utilization_valid) begin

        // CASE 1: GPU is currently LOW
        if (current_level == LOW) begin

            if (gpu_utilization >= 8'd85)
                recommended_level = HIGH;

            else if (gpu_utilization >= 8'd40)
                recommended_level = MEDIUM;

            else
                recommended_level = LOW;

        end

        // CASE 2: GPU is currently MEDIUM
        else if (current_level == MEDIUM) begin

            if (gpu_utilization >= 8'd75)
                recommended_level = HIGH;

            else if (gpu_utilization <= 8'd25)
                recommended_level = LOW;

            else
                recommended_level = MEDIUM;

        end
        
        // CASE 3: GPU is currently HIGH
else if (current_level == HIGH) begin

    if (gpu_utilization <= 8'd15)
        recommended_level = LOW;

    else if (gpu_utilization <= 8'd55)
        recommended_level = MEDIUM;

    else
        recommended_level = HIGH;

end

    end
end

endmodule
