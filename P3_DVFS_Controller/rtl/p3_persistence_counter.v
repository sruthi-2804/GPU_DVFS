
`timescale 1ns / 1ps

module p3_persistence_counter #(
    parameter integer PERSIST_THRESHOLD = 3
)(
    input wire clk,
    input wire rst_n,
    input wire class_valid,
    input wire [1:0] workload_class,

    output reg [1:0] stable_class,
    output reg stable_valid
);

    // Calculate counter width
    localparam integer COUNT_WIDTH =
        (PERSIST_THRESHOLD > 1) ?
        $clog2(PERSIST_THRESHOLD + 1) : 1;

    // Count consecutive matching valid epochs
    reg [COUNT_WIDTH-1:0] persist_count;

    // Store classification of current streak
    reg [1:0] last_class;

    // Indicates whether a previous class exists
    reg have_last_class;

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            persist_count   <= 0;
            last_class      <= 2'b00;
            have_last_class <= 1'b0;
            stable_class    <= 2'b00;
            stable_valid    <= 1'b0;
        end

        else if (class_valid) begin

            // Reject invalid workload class
            if (workload_class == 2'b11) begin
                persist_count   <= 0;
                have_last_class <= 1'b0;
            end

            // First valid class or class changed
            else if (!have_last_class ||
                     workload_class != last_class) begin

                last_class      <= workload_class;
                have_last_class <= 1'b1;
                persist_count   <= 1;

                // Handle threshold = 1
                if (PERSIST_THRESHOLD == 1) begin
                    stable_class <= workload_class;
                    stable_valid <= 1'b1;
                end
            end

            // Same class: increment counter
            else if (persist_count < PERSIST_THRESHOLD) begin

                persist_count <= persist_count + 1'b1;

                // Check if threshold is reached
                if (persist_count == PERSIST_THRESHOLD - 1) begin
                    stable_class <= workload_class;
                    stable_valid <= 1'b1;
                end
            end

            // At threshold: counter holds its value

        end
    end

endmodule
