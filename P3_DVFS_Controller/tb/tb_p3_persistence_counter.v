`timescale 1ns / 1ps

module tb_p3_persistence_counter;

    reg clk;
    reg rst_n;
    reg class_valid;
    reg [1:0] workload_class;

    wire [1:0] stable_class;
    wire stable_valid;

    localparam LOW  = 2'b00;
    localparam HIGH = 2'b10;

    integer errors;

    // Instantiate Design Under Test
    p3_persistence_counter #(
        .PERSIST_THRESHOLD(3)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .class_valid(class_valid),
        .workload_class(workload_class),
        .stable_class(stable_class),
        .stable_valid(stable_valid)
    );

    // Clock period = 10 ns
    initial clk = 0;
    always #5 clk = ~clk;

    // Send one valid workload classification
    task send_class;
        input [1:0] new_class;
        begin
            @(negedge clk);
            workload_class = new_class;
            class_valid = 1;

            @(negedge clk);
            class_valid = 0;
        end
    endtask

    // Check stable outputs
    task check_output;
        input [1:0] expected_class;
        input expected_valid;
        begin
            #1;
            if (stable_class !== expected_class ||
                stable_valid !== expected_valid) begin

                $display("FAIL: expected class=%b valid=%b, got class=%b valid=%b",
                    expected_class, expected_valid,
                    stable_class, stable_valid);

                errors = errors + 1;
            end
            else begin
                $display("PASS: class=%b valid=%b",
                    stable_class, stable_valid);
            end
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 0;
        class_valid = 0;
        workload_class = LOW;

        repeat (2) @(negedge clk);
        check_output(LOW, 0);

        rst_n = 1;

        // TEST 1: Three consecutive HIGH epochs
        $display("TEST 1: Stable HIGH");
        send_class(HIGH);
        check_output(LOW, 0);

        send_class(HIGH);
        check_output(LOW, 0);

        send_class(HIGH);
        check_output(HIGH, 1);

        // TEST 2: Change to LOW
        $display("TEST 2: Change to LOW");
        send_class(LOW);
        check_output(HIGH, 1);

        send_class(LOW);
        check_output(HIGH, 1);

        send_class(LOW);
        check_output(LOW, 1);

        // TEST 3: Reset
        $display("TEST 3: Reset");
        @(negedge clk);
        rst_n = 0;
        check_output(LOW, 0);

        rst_n = 1;

        // TEST 4: Counter saturation
        $display("TEST 4: Saturation");
        repeat (5) send_class(HIGH);
        check_output(HIGH, 1);

        if (dut.persist_count !== 3)
            errors = errors + 1;
       // TEST 5: Interrupted HIGH sequence
$display("TEST 5: Interrupted HIGH sequence");

// Start with a clean state
@(negedge clk);
rst_n = 0;
@(negedge clk);
rst_n = 1;

// Two HIGH epochs: not enough
send_class(HIGH);
check_output(LOW, 0);

send_class(HIGH);
check_output(LOW, 0);

// LOW interrupts the HIGH streak
send_class(LOW);
check_output(LOW, 0);

// HIGH streak must restart from 1
send_class(HIGH);
check_output(LOW, 0);

send_class(HIGH);
check_output(LOW, 0);


// TEST 6: Invalid workload class
$display("TEST 6: Invalid workload class");

// Reset before test
@(negedge clk);
rst_n = 0;
@(negedge clk);
rst_n = 1;

// Two HIGH epochs
send_class(HIGH);
send_class(HIGH);
check_output(LOW, 0);

// Invalid class interrupts the streak
send_class(2'b11);
check_output(LOW, 0);

// HIGH must start counting again
send_class(HIGH);
check_output(LOW, 0);

send_class(HIGH);
check_output(LOW, 0);

send_class(HIGH);
check_output(HIGH, 1);


// TEST 7: No counting when class_valid = 0
$display("TEST 7: class_valid gating");

// Reset
@(negedge clk);
rst_n = 0;
@(negedge clk);
rst_n = 1;

// First valid HIGH epoch
send_class(HIGH);
check_output(LOW, 0);

// Hold class_valid LOW for 5 clock cycles
repeat (5) @(negedge clk);

// Counter must remain at 1
if (dut.persist_count !== 1) begin
    $display("FAIL: Counter changed without class_valid");
    errors = errors + 1;
end
else begin
    $display("PASS: Counter held at 1");
end

// Second valid HIGH epoch
send_class(HIGH);
check_output(LOW, 0);

// Third valid HIGH epoch
send_class(HIGH);
check_output(HIGH, 1);


// Third consecutive HIGH is accepted
send_class(HIGH);
check_output(HIGH, 1);
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TESTS FAILED: %0d errors", errors);

        $finish;
    end

endmodule
