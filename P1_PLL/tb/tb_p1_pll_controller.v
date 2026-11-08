`timescale 1ns / 1ps

// Directed tests for the P1 frequency transition controller.
//
// The PLL here is a simulation stand-in only, not the Session 2 clock model.
// It is clocked and level-sensitive: it drops lock while pll_reconfig_en is
// high and relocks LOCK_LATENCY cycles later. hold_unlocked lets a test keep
// it unlocked to exercise the timeout and lock-loss paths.

module tb_p1_pll_controller;

    localparam CLK_PERIOD = 10;       // arbitrary, P1 does not fix clk_ref
    localparam RECONFIG_CYCLES = 4;
    localparam LOCK_TIMEOUT = 32;
    localparam LOCK_LATENCY = 6;

    localparam [1:0]
        LOW     = 2'b00,
        MEDIUM  = 2'b01,
        HIGH    = 2'b10,
        INVALID = 2'b11;

    reg clk_ref;
    reg rst_n;
    reg freq_req;
    reg [1:0] freq_sel;
    reg err_clear;

    wire freq_ack;
    wire pll_done;
    wire pll_busy;
    wire pll_error;
    wire pll_locked;
    wire [1:0] current_freq_sel;
    wire clock_valid;
    wire pll_reconfig_en;
    wire [1:0] pll_freq_code;

    reg pll_lock_in;
    reg hold_unlocked;

    integer pass_count = 0;
    integer fail_count = 0;

    // Maintained by the monitors below
    integer ack_count = 0;
    reg saw_reconfig;
    reg ack_prev;

    p1_pll_controller #(
        .RECONFIG_CYCLES(RECONFIG_CYCLES),
        .LOCK_TIMEOUT(LOCK_TIMEOUT)
    ) dut (
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

    initial begin
        clk_ref = 1'b0;
        forever #(CLK_PERIOD / 2) clk_ref = ~clk_ref;
    end

    // Behavioral PLL stand-in
    reg [7:0] lock_count;

    always @(posedge clk_ref or negedge rst_n) begin
        if (!rst_n) begin
            pll_lock_in <= 1'b0;
            lock_count  <= 8'd0;
        end
        else if (pll_reconfig_en || hold_unlocked) begin
            pll_lock_in <= 1'b0;
            lock_count  <= 8'd0;
        end
        else if (!pll_lock_in) begin
            if (lock_count >= LOCK_LATENCY - 1)
                pll_lock_in <= 1'b1;
            else
                lock_count <= lock_count + 8'd1;
        end
    end

    // Monitors that run for the whole simulation
    always @(posedge clk_ref) begin
        if (rst_n) begin
            if (freq_ack) begin
                ack_count = ack_count + 1;
                if (ack_prev) begin
                    fail_count = fail_count + 1;
                    $display("FAIL: freq_ack high for two cycles at %0t", $time);
                end
            end

            if (pll_reconfig_en)
                saw_reconfig = 1'b1;

            if (pll_busy && pll_done) begin
                fail_count = fail_count + 1;
                $display("FAIL: pll_busy and pll_done both high at %0t", $time);
            end

            if (freq_ack && !pll_done) begin
                fail_count = fail_count + 1;
                $display("FAIL: freq_ack without pll_done at %0t", $time);
            end
        end

        ack_prev = freq_ack && rst_n;
    end

    // Check tasks. name is 40 characters wide.
    task check;
        input [319:0] name;
        input actual;
        input expected;
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display("PASS: %0s", name);
            end
            else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s expected=%b got=%b", name, expected, actual);
            end
        end
    endtask

    task check_level;
        input [319:0] name;
        input [1:0] actual;
        input [1:0] expected;
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display("PASS: %0s", name);
            end
            else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s expected=%b got=%b", name, expected, actual);
            end
        end
    endtask

    task check_int;
        input [319:0] name;
        input integer actual;
        input integer expected;
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display("PASS: %0s (%0d)", name, actual);
            end
            else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s expected=%0d got=%0d", name, expected, actual);
            end
        end
    endtask

    // Raise a request and wait for the level acknowledgement
    task request_and_wait;
        input [1:0] sel;
        begin
            @(negedge clk_ref);
            freq_sel = sel;
            freq_req = 1'b1;
            wait (pll_done === 1'b1);
            @(negedge clk_ref);
            freq_req = 1'b0;
            wait (pll_done === 1'b0);
            @(negedge clk_ref);
        end
    endtask

    // Raise a request and drop it again without waiting for pll_done
    task request_and_abandon;
        input [1:0] sel;
        input [31:0] cycles;
        integer i;
        begin
            @(negedge clk_ref);
            freq_sel = sel;
            freq_req = 1'b1;
            for (i = 0; i < cycles; i = i + 1)
                @(negedge clk_ref);
            freq_req = 1'b0;
            @(negedge clk_ref);
        end
    endtask

    task pulse_err_clear;
        begin
            @(negedge clk_ref);
            err_clear = 1'b1;
            @(negedge clk_ref);
            err_clear = 1'b0;
        end
    endtask

    integer ack_mark;

    initial begin
        $display("=== P1 PLL CONTROLLER TEST START ===");

        rst_n         = 1'b0;
        freq_req      = 1'b0;
        freq_sel      = LOW;
        err_clear     = 1'b0;
        hold_unlocked = 1'b0;
        saw_reconfig  = 1'b0;
        ack_prev      = 1'b0;

        repeat (4) @(negedge clk_ref);

        // Test 1: outputs are quiet in reset
        check ("reset: pll_busy low",    pll_busy,    1'b0);
        check ("reset: pll_done low",    pll_done,    1'b0);
        check ("reset: freq_ack low",    freq_ack,    1'b0);
        check ("reset: pll_error low",   pll_error,   1'b0);
        check ("reset: clock_valid low", clock_valid, 1'b0);
        check_level("reset: current_freq_sel LOW", current_freq_sel, LOW);
        check_level("reset: pll_freq_code LOW",    pll_freq_code,    LOW);

        rst_n = 1'b1;

        // Test 2: initial bring-up at the reset code, no acknowledgement
        ack_mark = ack_count;
        wait (clock_valid === 1'b1);
        @(negedge clk_ref);
        check ("bring-up: pll_locked high", pll_locked, 1'b1);
        check_level("bring-up: reports LOW", current_freq_sel, LOW);
        check_int("bring-up: no freq_ack",  ack_count - ack_mark, 0);
        check ("bring-up: pll_error low",   pll_error, 1'b0);

        // Test 3: a normal transition to HIGH
        ack_mark     = ack_count;
        saw_reconfig = 1'b0;
        request_and_wait(HIGH);
        check_int("LOW to HIGH: one freq_ack", ack_count - ack_mark, 1);
        check_level("LOW to HIGH: reports HIGH", current_freq_sel, HIGH);
        check_level("LOW to HIGH: code is HIGH", pll_freq_code,    HIGH);
        check ("LOW to HIGH: clock_valid",  clock_valid, 1'b1);
        check ("LOW to HIGH: reconfigured", saw_reconfig, 1'b1);
        check ("LOW to HIGH: pll_busy low", pll_busy, 1'b0);
        check ("LOW to HIGH: no error",     pll_error, 1'b0);

        // Test 4: a request for the running frequency must not touch the PLL
        ack_mark     = ack_count;
        saw_reconfig = 1'b0;
        request_and_wait(HIGH);
        check_int("same state: one freq_ack", ack_count - ack_mark, 1);
        check ("same state: no reconfigure",  saw_reconfig, 1'b0);
        check_level("same state: still HIGH", current_freq_sel, HIGH);
        check ("same state: clock_valid held", clock_valid, 1'b1);

        // Test 5: the reserved encoding is rejected
        ack_mark     = ack_count;
        saw_reconfig = 1'b0;
        request_and_abandon(INVALID, 6);
        check_int("invalid: no freq_ack",    ack_count - ack_mark, 0);
        check ("invalid: no reconfigure",    saw_reconfig, 1'b0);
        check ("invalid: pll_error set",     pll_error, 1'b1);
        check ("invalid: clock still valid", clock_valid, 1'b1);
        check_level("invalid: level unchanged", current_freq_sel, HIGH);

        // Test 6: the sticky error is cleared only on request
        pulse_err_clear;
        @(negedge clk_ref);
        check ("sticky: error cleared", pll_error, 1'b0);

        // Test 7: lock never arrives, the timeout fires
        ack_mark      = ack_count;
        hold_unlocked = 1'b1;
        request_and_abandon(MEDIUM, RECONFIG_CYCLES + LOCK_TIMEOUT + 6);
        check_int("timeout: no freq_ack",  ack_count - ack_mark, 0);
        check ("timeout: pll_error set",   pll_error, 1'b1);
        check ("timeout: clock_valid low", clock_valid, 1'b0);
        check_level("timeout: level not committed", current_freq_sel, HIGH);
        check ("timeout: pll_busy low",    pll_busy, 1'b0);

        // Test 8: the same request succeeds once the PLL can lock again
        hold_unlocked = 1'b0;
        pulse_err_clear;
        ack_mark = ack_count;
        request_and_wait(MEDIUM);
        check_int("retry: one freq_ack", ack_count - ack_mark, 1);
        check_level("retry: reports MEDIUM", current_freq_sel, MEDIUM);
        check ("retry: clock_valid",  clock_valid, 1'b1);
        check ("retry: no new error", pll_error, 1'b0);

        // Test 9: reset asserted in the middle of a transition
        ack_mark = ack_count;
        @(negedge clk_ref);
        freq_sel = HIGH;
        freq_req = 1'b1;
        wait (pll_busy === 1'b1);
        repeat (RECONFIG_CYCLES + 1) @(negedge clk_ref);
        check ("mid-reset: busy before reset", pll_busy, 1'b1);
        rst_n = 1'b0;
        @(negedge clk_ref);
        check ("mid-reset: pll_busy low",    pll_busy, 1'b0);
        check ("mid-reset: pll_done low",    pll_done, 1'b0);
        check ("mid-reset: clock_valid low", clock_valid, 1'b0);
        check ("mid-reset: pll_error low",   pll_error, 1'b0);
        check_level("mid-reset: reports LOW", current_freq_sel, LOW);
        check_int("mid-reset: no freq_ack",  ack_count - ack_mark, 0);
        freq_req = 1'b0;
        rst_n    = 1'b1;
        wait (clock_valid === 1'b1);
        @(negedge clk_ref);

        // Test 10: lock lost during steady-state operation
        ack_mark      = ack_count;
        hold_unlocked = 1'b1;
        wait (clock_valid === 1'b0);
        @(negedge clk_ref);
        check ("lock loss: clock_valid low", clock_valid, 1'b0);
        check ("lock loss: pll_error set",   pll_error, 1'b1);
        hold_unlocked = 1'b0;
        wait (clock_valid === 1'b1);
        @(negedge clk_ref);
        check ("lock loss: recovered", clock_valid, 1'b1);
        check_level("lock loss: level unchanged", current_freq_sel, LOW);
        check_int("lock loss: no freq_ack", ack_count - ack_mark, 0);

        $display("==========================");
        $display("PASS = %0d  FAIL = %0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL P1 CONTROLLER TESTS PASSED");
        else
            $display("P1 CONTROLLER TESTS FAILED");
        $display("==========================");
        $finish;
    end

    // Watchdog
    initial begin
        #50000;
        $display("FAIL: watchdog expired, controller stalled");
        $finish;
    end

endmodule
