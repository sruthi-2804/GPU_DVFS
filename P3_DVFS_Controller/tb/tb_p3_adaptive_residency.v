
`timescale 1ns / 1ps

module tb_p3_adaptive_residency;

    reg clk;
    reg rst_n;
    reg transition_done;
    reg urgent_change;
    reg frequent_switching;

    wire residency_done;

    integer errors;
    integer tests;

    // Device Under Test
    p3_adaptive_residency dut (
        .clk(clk),
        .rst_n(rst_n),
        .transition_done(transition_done),
        .urgent_change(urgent_change),
        .frequent_switching(frequent_switching),
        .residency_done(residency_done)
    );

    // 10 ns clock period
    initial clk = 0;
    always #5 clk = ~clk;

    // Check expected residency status
    task check_done;
        input expected;
        begin
            tests = tests + 1;
            #1;
            if (residency_done !== expected) begin
                $display("FAIL: Test %0d at %0t, expected=%b, got=%b",
                         tests, $time, expected, residency_done);
                errors = errors + 1;
            end
            else begin
                $display("PASS: Test %0d at %0t", tests, $time);
            end
        end
    endtask

    // Start a completed DVFS transition
    task start_transition;
        input urgent;
        input frequent;
        begin
            @(negedge clk);
            urgent_change = urgent;
            frequent_switching = frequent;
            transition_done = 1;

            @(posedge clk);
            #1;

            @(negedge clk);
            transition_done = 0;
            urgent_change = 0;
            frequent_switching = 0;
        end
    endtask

    // Wait for a specified number of rising edges
    task wait_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                #1;
            end
        end
    endtask

    initial begin
        errors = 0;
        tests = 0;

        rst_n = 0;
        transition_done = 0;
        urgent_change = 0;
        frequent_switching = 0;

        // TEST 1: Reset
        #2;
        check_done(1);

        @(negedge clk);
        rst_n = 1;

        // TEST 2: NORMAL residency = 4 cycles
        $display("Testing NORMAL residency");
        start_transition(0, 0);
        check_done(0);

        wait_cycles(3);
        check_done(0);

        wait_cycles(1);
        check_done(1);

        // TEST 3: SHORT residency = 2 cycles
        $display("Testing SHORT residency");
        start_transition(1, 0);
        check_done(0);

        wait_cycles(1);
        check_done(0);

        wait_cycles(1);
        check_done(1);

        // TEST 4: LONG residency = 8 cycles
        $display("Testing LONG residency");
        start_transition(0, 1);
        check_done(0);

        wait_cycles(7);
        check_done(0);

        wait_cycles(1);
        check_done(1);

        // TEST 5: Frequent switching overrides urgency
        $display("Testing priority");
        start_transition(1, 1);
        check_done(0);

        wait_cycles(2);
        check_done(0);

        wait_cycles(6);
        check_done(1);

        // TEST 6: Counter saturation
        $display("Testing saturation");
        wait_cycles(10);
        check_done(1);

        if (dut.residency_count !== 8) begin
            $display("FAIL: Counter did not saturate at 8");
            errors = errors + 1;
        end
        else begin
            $display("PASS: Counter saturation");
        end

        // TEST 7: New transition restarts residency
        $display("Testing transition restart");
        start_transition(0, 0);
        check_done(0);

        wait_cycles(4);
        check_done(1);
// TEST 8: Reset during active residency
$display("Testing reset during residency");

// Start LONG residency (8 cycles)
start_transition(0, 1);

// Allow only 3 residency cycles to pass
wait_cycles(3);

// Residency should still be blocking
check_done(0);

// Assert active-low reset between clock edges
@(negedge clk);
#1;
rst_n = 0;

// Check asynchronous reset response
#1;
check_done(1);

// Verify internal registers were cleared
if (dut.residency_count !== 0 ||
    dut.residency_limit !== 0) begin
    $display("FAIL: Reset did not clear residency registers");
    errors = errors + 1;
end
else begin
    $display("PASS: Reset cleared residency registers");
end

// Release reset before starting Test 9
@(negedge clk);
rst_n = 1;

// TEST 9: Urgency changes during residency
$display("TEST 9: Urgency changes during residency");

start_transition(0, 0);  // NORMAL = 4 cycles
check_done(0);

wait_cycles(1);

@(negedge clk);
urgent_change = 1;       // Proposed limit changes to 2

wait_cycles(2);          // Count reaches 3
check_done(0);           // Still blocked

if (dut.residency_limit !== 4) begin
    $display("FAIL: Stored limit changed");
    errors = errors + 1;
end
else
    $display("PASS: Stored limit remains 4");

wait_cycles(1);          // Count reaches 4
check_done(1);

@(negedge clk);
urgent_change = 0;


// TEST 10: Back-to-back transition_done pulses
$display("TEST 10: Back-to-back completion pulses");

@(negedge clk);
transition_done = 1;
urgent_change = 0;
frequent_switching = 0;

@(posedge clk);
#1;
check_done(0);

@(negedge clk);
urgent_change = 1;       // Select SHORT for second pulse

@(posedge clk);
#1;

if (dut.residency_count !== 0 ||
    dut.residency_limit !== 2) begin
    $display("FAIL: Consecutive completion handling");
    errors = errors + 1;
end
else
    $display("PASS: Consecutive completion handling");

check_done(0);

@(negedge clk);
transition_done = 0;
urgent_change = 0;

wait_cycles(1);
check_done(0);

wait_cycles(1);
check_done(1);


// TEST 11: Residency remains complete after limit
$display("TEST 11: Residency remains complete");

wait_cycles(5);
check_done(1);

if (dut.residency_count !== 2) begin
    $display("FAIL: Counter exceeded SHORT limit");
    errors = errors + 1;
end
else
    $display("PASS: SHORT counter saturation");

        // Final results
        $display("----------------------------");
        $display("Tests completed: %0d", tests);
        $display("Errors: %0d", errors);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TESTBENCH FAILED");

        $finish;
    end

endmodule
