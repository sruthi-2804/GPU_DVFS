
`timescale 1ns / 1ps

module tb_p3_hysteresis_controller;

    reg [7:0] gpu_utilization;
    reg utilization_valid;
    reg [1:0] current_level;

    wire [1:0] recommended_level;

    integer pass_count = 0;
    integer fail_count = 0;

    localparam LOW    = 2'b00;
    localparam MEDIUM = 2'b01;
    localparam HIGH   = 2'b10;

    // Design Under Test
    p3_hysteresis_controller dut (
        .gpu_utilization(gpu_utilization),
        .utilization_valid(utilization_valid),
        .current_level(current_level),
        .recommended_level(recommended_level)
    );

    // Reusable test procedure
    task check;
        input [1:0] level;
        input [7:0] util;
        input valid;
        input [1:0] expected;
        begin
            current_level = level;
            gpu_utilization = util;
            utilization_valid = valid;

            #10;

            if (recommended_level === expected) begin
                pass_count = pass_count + 1;
                $display("PASS: level=%b util=%0d valid=%b result=%b",
                         level, util, valid, recommended_level);
            end
            else begin
                fail_count = fail_count + 1;
                $display("FAIL: level=%b util=%0d valid=%b expected=%b got=%b",
                         level, util, valid, expected, recommended_level);
            end
        end
    endtask

    initial begin
        $display("=== P3 HYSTERESIS TEST START ===");

        // Test 1: Direct LOW -> HIGH
        check(LOW, 90, 1, HIGH);

        // Test 2: LOW -> MEDIUM
        check(LOW, 50, 1, MEDIUM);

        // Test 3: LOW remains LOW
        check(LOW, 20, 1, LOW);

        // Test 4: MEDIUM -> HIGH
        check(MEDIUM, 80, 1, HIGH);

        // Test 5: MEDIUM remains MEDIUM
        check(MEDIUM, 50, 1, MEDIUM);

        // Test 6: MEDIUM -> LOW
        check(MEDIUM, 20, 1, LOW);

        // Test 7: Direct HIGH -> LOW
        check(HIGH, 10, 1, LOW);

        // Test 8: HIGH -> MEDIUM
        check(HIGH, 40, 1, MEDIUM);

        // Test 9: HIGH remains HIGH
        check(HIGH, 70, 1, HIGH);

        // Test 10: Invalid utilization holds current level
        check(MEDIUM, 90, 0, MEDIUM);

        // Test 11: Exact threshold boundaries
        check(HIGH,   15, 1, LOW);
        check(MEDIUM, 25, 1, LOW);
        check(LOW,    40, 1, MEDIUM);
        check(HIGH,   55, 1, MEDIUM);
        check(MEDIUM, 75, 1, HIGH);
        check(LOW,    85, 1, HIGH);

        // Test 12: Invalid level (current RTL behavior)
        check(2'b11, 50, 1, 2'b11);

        $display("=================================");
        $display("TOTAL CHECKS: %0d", pass_count + fail_count);
        $display("PASSED: %0d", pass_count);
        $display("FAILED: %0d", fail_count);
        $display("=================================");

        if (fail_count == 0)
            $display("ALL HYSTERESIS TESTS PASSED");
        else
            $display("HYSTERESIS TESTS FAILED");

        $finish;
    end

endmodule
