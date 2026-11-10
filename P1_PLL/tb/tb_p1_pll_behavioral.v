`timescale 1ns / 1ps

// Directed tests for the behavioral PLL and GPU clock model, driven directly
// rather than through the controller. Periods are measured from the generated
// waveform with an explicit tolerance, not inferred from the frequency code.

module tb_p1_pll_behavioral;

    localparam CLK_PERIOD = 10;          // clk_ref, arbitrary
    localparam PERIOD_LOW_PS = 20000;
    localparam PERIOD_MED_PS = 10000;
    localparam PERIOD_HIGH_PS = 5000;
    localparam STARTUP_CYCLES = 20;
    localparam MIN_SETTLE_CYCLES = 1;

    // Timing tolerance for every real comparison, in nanoseconds
    localparam real TOL_NS = 0.01;

    localparam [1:0]
        LOW     = 2'b00,
        MEDIUM  = 2'b01,
        HIGH    = 2'b10,
        INVALID = 2'b11;

    reg clk_ref;
    reg rst_n;
    reg pll_reconfig_en;
    reg [1:0] pll_freq_code;
    reg [15:0] settle_cycles;

    wire pll_lock_in;
    wire gpu_clk;
    wire cfg_reject;

    integer pass_count = 0;
    integer fail_count = 0;

    // Free-running clk_ref cycle counter, used to time the settling interval
    integer cyc_count = 0;

    // gpu_clk rising edges seen so far
    integer gpu_edges = 0;

    real meas_period;
    real meas_high;

    p1_pll_behavioral #(
        .PERIOD_LOW_PS(PERIOD_LOW_PS),
        .PERIOD_MED_PS(PERIOD_MED_PS),
        .PERIOD_HIGH_PS(PERIOD_HIGH_PS),
        .STARTUP_CYCLES(STARTUP_CYCLES),
        .MIN_SETTLE_CYCLES(MIN_SETTLE_CYCLES)
    ) dut (
        .clk_ref(clk_ref),
        .rst_n(rst_n),
        .pll_reconfig_en(pll_reconfig_en),
        .pll_freq_code(pll_freq_code),
        .settle_cycles(settle_cycles),
        .pll_lock_in(pll_lock_in),
        .gpu_clk(gpu_clk),
        .cfg_reject(cfg_reject)
    );

    initial begin
        clk_ref = 1'b0;
        forever #(CLK_PERIOD / 2) clk_ref = ~clk_ref;
    end

    always @(posedge clk_ref) begin
        cyc_count = cyc_count + 1;
    end

    // The model must never produce a rising GPU clock edge while unlocked.
    // A falling edge is allowed: a stop request is honoured only at the end of
    // the half period in progress, so the last pulse always completes.
    always @(posedge gpu_clk) begin
        gpu_edges = gpu_edges + 1;
        if (pll_lock_in !== 1'b1) begin
            fail_count = fail_count + 1;
            $display("FAIL: gpu_clk rising edge while unlocked at %0t", $time);
        end
    end

    task check_bit;
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

    task check_real;
        input [319:0] name;
        input real actual;
        input real expected;
        begin
            if (actual >= expected - TOL_NS && actual <= expected + TOL_NS) begin
                pass_count = pass_count + 1;
                $display("PASS: %0s (%0.3f ns)", name, actual);
            end
            else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s expected=%0.3f ns got=%0.3f ns",
                         name, expected, actual);
            end
        end
    endtask

    // Measure one full period and its high time from the live waveform
    task measure_clock;
        real t1;
        real t2;
        real t3;
        begin
            @(posedge gpu_clk);
            t1 = $realtime;
            @(negedge gpu_clk);
            t2 = $realtime;
            @(posedge gpu_clk);
            t3 = $realtime;
            meas_period = t3 - t1;
            meas_high   = t2 - t1;
        end
    endtask

    // Program a new code and report how many clk_ref cycles settling took
    integer t_drop;
    integer settle_observed;
    integer edges_while_unlocked;

    task reconfigure;
        input [1:0] code;
        input [15:0] cycles;
        input [31:0] strobe_cycles;
        integer i;
        begin
            @(negedge clk_ref);
            settle_cycles   = cycles;
            pll_freq_code   = code;
            pll_reconfig_en = 1'b1;
            for (i = 0; i < strobe_cycles; i = i + 1)
                @(negedge clk_ref);
            pll_reconfig_en = 1'b0;
            t_drop               = cyc_count;
            edges_while_unlocked = gpu_edges;
        end
    endtask

    task wait_lock;
        begin
            @(posedge pll_lock_in);
            settle_observed      = cyc_count - t_drop;
            edges_while_unlocked = gpu_edges - edges_while_unlocked;
        end
    endtask

    integer edge_mark;
    real p1;
    real p2;
    real p3;

    initial begin
        $display("=== P1 BEHAVIORAL PLL TEST START ===");

        rst_n           = 1'b0;
        pll_reconfig_en = 1'b0;
        pll_freq_code   = LOW;
        settle_cycles   = 16'd1;

        repeat (4) @(negedge clk_ref);

        // Test 1: the model is quiet in reset
        check_bit("reset: pll_lock_in low", pll_lock_in, 1'b0);
        check_bit("reset: gpu_clk low",     gpu_clk,     1'b0);
        check_bit("reset: cfg_reject low",  cfg_reject,  1'b0);
        check_int("reset: no gpu_clk edges", gpu_edges,  0);

        // Test 2: startup locks at the LOW code after exactly STARTUP_CYCLES
        @(negedge clk_ref);
        t_drop = cyc_count;
        rst_n  = 1'b1;
        @(posedge pll_lock_in);
        check_int("startup: lock latency", cyc_count - t_drop, STARTUP_CYCLES);
        check_bit("startup: code is LOW", (dut.code_r === LOW), 1'b1);

        // Test 3: LOW period and duty cycle, measured from the waveform
        measure_clock;
        check_real("LOW period",   meas_period, PERIOD_LOW_PS / 1000.0);
        check_real("LOW high time", meas_high,  PERIOD_LOW_PS / 2000.0);

        // Test 4: LOW to MEDIUM, settling counted in clk_ref cycles
        reconfigure(MEDIUM, 16'd10, 4);
        check_bit("LOW->MED: lock dropped", pll_lock_in, 1'b0);
        check_bit("LOW->MED: clock stopped", gpu_clk,    1'b0);
        wait_lock;
        check_int("LOW->MED: settle cycles", settle_observed, 10);
        check_int("LOW->MED: no edges while unlocked", edges_while_unlocked, 0);
        measure_clock;
        check_real("MEDIUM period",    meas_period, PERIOD_MED_PS / 1000.0);
        check_real("MEDIUM high time", meas_high,   PERIOD_MED_PS / 2000.0);

        // Test 5: MEDIUM to HIGH
        reconfigure(HIGH, 16'd12, 4);
        wait_lock;
        check_int("MED->HIGH: settle cycles", settle_observed, 12);
        check_int("MED->HIGH: no edges while unlocked", edges_while_unlocked, 0);
        measure_clock;
        check_real("HIGH period",    meas_period, PERIOD_HIGH_PS / 1000.0);
        check_real("HIGH high time", meas_high,   PERIOD_HIGH_PS / 2000.0);

        // Test 6: HIGH to LOW, and the period returns to its earlier value
        reconfigure(LOW, 16'd14, 4);
        wait_lock;
        check_int("HIGH->LOW: settle cycles", settle_observed, 14);
        measure_clock;
        check_real("LOW period again", meas_period, PERIOD_LOW_PS / 1000.0);

        // Test 7: the clock is stable over several cycles after switching
        measure_clock; p1 = meas_period;
        measure_clock; p2 = meas_period;
        measure_clock; p3 = meas_period;
        check_real("stable period 1", p1, PERIOD_LOW_PS / 1000.0);
        check_real("stable period 2", p2, PERIOD_LOW_PS / 1000.0);
        check_real("stable period 3", p3, PERIOD_LOW_PS / 1000.0);

        // Test 8: a zero-cost entry is floored, so lock is never immediate
        reconfigure(MEDIUM, 16'd0, 4);
        wait_lock;
        check_int("zero cost floored to MIN_SETTLE_CYCLES",
                  settle_observed, MIN_SETTLE_CYCLES);

        // Test 9: the reserved code is rejected and leaves the model unlocked.
        // The edge window starts after the strobe falls: the model samples the
        // strobe on clk_ref, so the clock keeps running for up to one control
        // cycle after the request, at the old and still valid frequency.
        reconfigure(INVALID, 16'd4, 4);
        edge_mark = gpu_edges;
        repeat (20) @(negedge clk_ref);
        check_bit("reserved: cfg_reject set",  cfg_reject,  1'b1);
        check_bit("reserved: stays unlocked",  pll_lock_in, 1'b0);
        check_bit("reserved: clock stopped",   gpu_clk,     1'b0);
        check_int("reserved: no gpu_clk edges", gpu_edges - edge_mark, 0);

        // Test 10: a valid code afterwards recovers
        reconfigure(HIGH, 16'd6, 4);
        wait_lock;
        check_bit("recovery: cfg_reject cleared", cfg_reject, 1'b0);
        check_int("recovery: settle cycles", settle_observed, 6);
        measure_clock;
        check_real("recovery: HIGH period", meas_period, PERIOD_HIGH_PS / 1000.0);

        // Test 11: a reconfiguration arriving mid-settle restarts the sequence
        reconfigure(LOW, 16'd30, 4);
        repeat (8) @(negedge clk_ref);
        check_bit("mid-settle: still unlocked", pll_lock_in, 1'b0);
        reconfigure(MEDIUM, 16'd5, 4);
        wait_lock;
        check_int("mid-settle: restarted settle cycles", settle_observed, 5);
        check_bit("mid-settle: final code is MEDIUM", (dut.code_r === MEDIUM), 1'b1);
        measure_clock;
        check_real("mid-settle: MEDIUM period", meas_period, PERIOD_MED_PS / 1000.0);

        // Test 12: reset asserted while settling returns a defined state
        reconfigure(HIGH, 16'd30, 4);
        repeat (6) @(negedge clk_ref);
        rst_n = 1'b0;
        @(negedge clk_ref);
        check_bit("reset in settle: lock low", pll_lock_in, 1'b0);
        check_bit("reset in settle: clock low", gpu_clk,    1'b0);
        check_bit("reset in settle: code back to LOW", (dut.code_r === LOW), 1'b1);
        @(negedge clk_ref);
        t_drop = cyc_count;
        rst_n  = 1'b1;
        @(posedge pll_lock_in);
        check_int("reset in settle: restarts startup",
                  cyc_count - t_drop, STARTUP_CYCLES);
        measure_clock;
        check_real("reset in settle: LOW period", meas_period,
                   PERIOD_LOW_PS / 1000.0);

        // Test 13: reset asserted during startup
        @(negedge clk_ref);
        rst_n = 1'b0;
        repeat (3) @(negedge clk_ref);
        rst_n = 1'b1;
        repeat (5) @(negedge clk_ref);
        check_bit("reset in startup: still unlocked", pll_lock_in, 1'b0);
        @(posedge pll_lock_in);
        check_bit("reset in startup: eventually locks", pll_lock_in, 1'b1);

        // Test 14: repeated back-to-back transitions
        reconfigure(MEDIUM, 16'd3, 4); wait_lock;
        check_int("repeat 1 settle", settle_observed, 3);
        reconfigure(HIGH, 16'd3, 4); wait_lock;
        check_int("repeat 2 settle", settle_observed, 3);
        reconfigure(LOW, 16'd3, 4); wait_lock;
        check_int("repeat 3 settle", settle_observed, 3);
        measure_clock;
        check_real("repeat: LOW period", meas_period, PERIOD_LOW_PS / 1000.0);

        // Test 15: a single-cycle strobe is enough
        reconfigure(HIGH, 16'd4, 1);
        wait_lock;
        check_int("one-cycle strobe: settle cycles", settle_observed, 4);
        measure_clock;
        check_real("one-cycle strobe: HIGH period", meas_period,
                   PERIOD_HIGH_PS / 1000.0);

        $display("==========================");
        $display("PASS = %0d  FAIL = %0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("BEHAVIORAL PLL TESTS FAILED");
        $display("==========================");
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL: watchdog expired in tb_p1_pll_behavioral");
        $finish;
    end

endmodule
