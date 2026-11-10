`timescale 1ns / 1ps

// Integrated tests for the P1 wrapper: controller, transition-cost matrix and
// behavioral PLL together.
//
// Periods are measured from the generated gpu_clk waveform with an explicit
// tolerance. Transition durations are measured in clk_ref cycles and compared
// against the cost matrix, so a wrong matrix entry fails a test rather than
// quietly changing the timing.
//
// Expected pll_busy duration for a real change, in clk_ref cycles:
//   1 (ACCEPT) + RECONFIG_CYCLES + settle_cycles + 3 (2 synchroniser cycles
//   plus one for the FSM to act) = RECONFIG_CYCLES + settle_cycles + 4.
// A same-state request skips reconfiguration entirely and takes 1 cycle.

module tb_p1_pll_top;

    localparam CLK_PERIOD = 10;
    localparam RECONFIG_CYCLES = 4;
    localparam LOCK_TIMEOUT = 1024;
    localparam PERIOD_LOW_PS = 20000;
    localparam PERIOD_MED_PS = 10000;
    localparam PERIOD_HIGH_PS = 5000;
    localparam STARTUP_CYCLES = 20;

    // Settling cycles implied by the default matrix at a 10000 ps control clock
    localparam CYC_LOW_MED = 10;
    localparam CYC_LOW_HIGH = 18;
    localparam CYC_MED_LOW = 8;
    localparam CYC_MED_HIGH = 12;
    localparam CYC_HIGH_LOW = 14;
    localparam CYC_HIGH_MED = 9;

    localparam real TOL_NS = 0.01;

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

    wire pll_done;
    wire freq_ack;
    wire pll_busy;
    wire pll_error;
    wire pll_locked;
    wire [1:0] current_freq_sel;
    wire clock_valid;
    wire gpu_clk;

    // Inside the model, used for the clock-safety checks
    wire model_lock = dut.u_pll.pll_lock_in;
    wire model_reject = dut.u_pll.cfg_reject;
    wire [15:0] cost_cycles = dut.settle_cycles;

    integer pass_count = 0;
    integer fail_count = 0;

    integer cyc_count = 0;
    integer gpu_edges = 0;
    integer ack_count = 0;

    reg busy_q;
    reg ack_q;
    reg cv_q;
    reg lk_q;
    reg rc_q;
    integer busy_start;
    integer busy_len;
    integer cost_at_reconfig;
    integer cv_fall;
    integer cv_rise;
    integer lk_fall;
    integer lk_rise;

    real meas_period;
    real meas_high;

    p1_pll_top #(
        .RECONFIG_CYCLES(RECONFIG_CYCLES),
        .LOCK_TIMEOUT(LOCK_TIMEOUT),
        .PERIOD_LOW_PS(PERIOD_LOW_PS),
        .PERIOD_MED_PS(PERIOD_MED_PS),
        .PERIOD_HIGH_PS(PERIOD_HIGH_PS),
        .STARTUP_CYCLES(STARTUP_CYCLES)
    ) dut (
        .clk_ref(clk_ref),
        .rst_n(rst_n),
        .freq_req(freq_req),
        .freq_sel(freq_sel),
        .err_clear(err_clear),
        .pll_done(pll_done),
        .freq_ack(freq_ack),
        .pll_busy(pll_busy),
        .pll_error(pll_error),
        .pll_locked(pll_locked),
        .current_freq_sel(current_freq_sel),
        .clock_valid(clock_valid),
        .gpu_clk(gpu_clk)
    );

    initial begin
        clk_ref = 1'b0;
        forever #(CLK_PERIOD / 2) clk_ref = ~clk_ref;
    end

    // One block, so the cycle counter and every edge timestamp stay consistent
    always @(posedge clk_ref) begin
        cyc_count = cyc_count + 1;

        if (freq_ack === 1'b1) begin
            ack_count = ack_count + 1;
            if (ack_q === 1'b1) begin
                fail_count = fail_count + 1;
                $display("FAIL: freq_ack high for two cycles at %0t", $time);
            end
            if (pll_done !== 1'b1) begin
                fail_count = fail_count + 1;
                $display("FAIL: freq_ack without pll_done at %0t", $time);
            end
        end
        ack_q = freq_ack;

        if (pll_busy === 1'b1 && pll_done === 1'b1) begin
            fail_count = fail_count + 1;
            $display("FAIL: pll_busy and pll_done both high at %0t", $time);
        end

        if (pll_busy === 1'b1 && busy_q === 1'b0)
            busy_start = cyc_count;
        else if (pll_busy === 1'b0 && busy_q === 1'b1)
            busy_len = cyc_count - busy_start;
        busy_q = pll_busy;

        if (clock_valid === 1'b0 && cv_q === 1'b1) cv_fall = cyc_count;
        if (clock_valid === 1'b1 && cv_q === 1'b0) cv_rise = cyc_count;
        cv_q = clock_valid;

        if (model_lock === 1'b0 && lk_q === 1'b1) lk_fall = cyc_count;
        if (model_lock === 1'b1 && lk_q === 1'b0) lk_rise = cyc_count;
        lk_q = model_lock;

        // The cost lookup is only meaningful while a transition is in flight,
        // so sample it on the reconfiguration strobe rather than at idle.
        if (dut.pll_reconfig_en === 1'b1 && rc_q === 1'b0)
            cost_at_reconfig = cost_cycles;
        rc_q = dut.pll_reconfig_en;
    end

    // The GPU clock must never produce a rising edge while the PLL is unlocked.
    always @(posedge gpu_clk) begin
        gpu_edges = gpu_edges + 1;
        if (model_lock !== 1'b1) begin
            fail_count = fail_count + 1;
            $display("FAIL: gpu_clk rising edge while PLL unlocked at %0t", $time);
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

    // Drive a request exactly as P3 does: hold it until pll_done, then release
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

    // One full transition, checked end to end
    task do_transition;
        input [319:0] name;
        input [1:0] sel;
        input integer exp_settle;
        input real exp_period_ns;
        integer ack_mark;
        begin
            ack_mark = ack_count;
            request_and_wait(sel);
            check_int({name, " matrix cycles"}, cost_at_reconfig, exp_settle);
            check_int({name, " one ack"}, ack_count - ack_mark, 1);
            check_int({name, " busy cycles"}, busy_len,
                      RECONFIG_CYCLES + exp_settle + 4);
            check_level({name, " reports target"}, current_freq_sel, sel);
            check_bit({name, " clock_valid"}, clock_valid, 1'b1);
            check_bit({name, " no error"}, pll_error, 1'b0);
            measure_clock;
            check_real({name, " period"}, meas_period, exp_period_ns);
            check_real({name, " high time"}, meas_high, exp_period_ns / 2.0);
            // clock_valid must drop no later than the clock stops, and rise
            // only after lock is back
            check_bit({name, " cv falls before lock"},
                      (cv_fall <= lk_fall), 1'b1);
            check_bit({name, " cv rises after lock"},
                      (cv_rise > lk_rise), 1'b1);
            check_int({name, " cv lag after lock"}, cv_rise - lk_rise, 4);
        end
    endtask

    integer ack_mark;
    integer edge_mark;
    integer b1;
    integer b2;
    real p1;
    real p2;

    initial begin
        $display("=== P1 TOP TEST START ===");

        rst_n     = 1'b0;
        freq_req  = 1'b0;
        freq_sel  = LOW;
        err_clear = 1'b0;
        busy_q    = 1'b0;
        ack_q     = 1'b0;
        cv_q      = 1'b0;
        lk_q      = 1'b0;

        repeat (4) @(negedge clk_ref);

        // Test 1: everything quiet in reset, and no clock at all
        check_bit("reset: pll_busy low",     pll_busy,    1'b0);
        check_bit("reset: pll_done low",     pll_done,    1'b0);
        check_bit("reset: freq_ack low",     freq_ack,    1'b0);
        check_bit("reset: pll_error low",    pll_error,   1'b0);
        check_bit("reset: clock_valid low",  clock_valid, 1'b0);
        check_bit("reset: pll_locked low",   pll_locked,  1'b0);
        check_bit("reset: gpu_clk low",      gpu_clk,     1'b0);
        check_int("reset: no gpu_clk edges", gpu_edges,   0);
        check_level("reset: reports LOW", current_freq_sel, LOW);

        // Test 2: startup brings the clock up at LOW with no acknowledgement
        ack_mark = ack_count;
        rst_n = 1'b1;
        wait (clock_valid === 1'b1);
        @(negedge clk_ref);
        check_bit("startup: pll_locked high", pll_locked, 1'b1);
        check_level("startup: reports LOW", current_freq_sel, LOW);
        check_int("startup: no freq_ack", ack_count - ack_mark, 0);
        check_bit("startup: no error", pll_error, 1'b0);

        // Test 3: LOW period, straight from the waveform
        measure_clock;
        check_real("startup: LOW period",    meas_period, PERIOD_LOW_PS / 1000.0);
        check_real("startup: LOW high time", meas_high,   PERIOD_LOW_PS / 2000.0);

        // The edge timestamps are recorded by a clocked monitor, so they are
        // only readable a cycle after the signal itself moves.
        //
        // Startup lags lock by three cycles, one less than a completed
        // transition. The controller adopts the reset code from IDLE, so it
        // pays the two synchroniser cycles and one cycle to act, but never
        // passes through DONE.
        check_bit("startup: cv rises after lock", (cv_rise > lk_rise), 1'b1);
        check_int("startup: cv lag after lock", cv_rise - lk_rise, 3);

        // Tests 4 to 9: all six cross transitions, in both directions
        do_transition("LOW->MED",  MEDIUM, CYC_LOW_MED,  PERIOD_MED_PS  / 1000.0);
        do_transition("MED->HIGH", HIGH,   CYC_MED_HIGH, PERIOD_HIGH_PS / 1000.0);
        do_transition("HIGH->LOW", LOW,    CYC_HIGH_LOW, PERIOD_LOW_PS  / 1000.0);
        do_transition("LOW->HIGH", HIGH,   CYC_LOW_HIGH, PERIOD_HIGH_PS / 1000.0);
        do_transition("HIGH->MED", MEDIUM, CYC_HIGH_MED, PERIOD_MED_PS  / 1000.0);
        do_transition("MED->LOW",  LOW,    CYC_MED_LOW,  PERIOD_LOW_PS  / 1000.0);

        // Test 10: same-state requests complete without disturbing the clock.
        // This covers the three diagonal entries of the matrix.
        edge_mark = gpu_edges;
        ack_mark  = ack_count;
        request_and_wait(LOW);
        check_int("same LOW: one ack", ack_count - ack_mark, 1);
        check_int("same LOW: busy cycles", busy_len, 1);
        check_bit("same LOW: clock never stopped", clock_valid, 1'b1);
        check_bit("same LOW: model stayed locked", model_lock, 1'b1);
        measure_clock;
        check_real("same LOW: period unchanged", meas_period,
                   PERIOD_LOW_PS / 1000.0);

        request_and_wait(MEDIUM);
        ack_mark = ack_count;
        request_and_wait(MEDIUM);
        check_int("same MEDIUM: one ack", ack_count - ack_mark, 1);
        check_int("same MEDIUM: busy cycles", busy_len, 1);
        check_bit("same MEDIUM: clock_valid held", clock_valid, 1'b1);
        measure_clock;
        check_real("same MEDIUM: period", meas_period, PERIOD_MED_PS / 1000.0);

        request_and_wait(HIGH);
        ack_mark = ack_count;
        request_and_wait(HIGH);
        check_int("same HIGH: one ack", ack_count - ack_mark, 1);
        check_int("same HIGH: busy cycles", busy_len, 1);
        measure_clock;
        check_real("same HIGH: period", meas_period, PERIOD_HIGH_PS / 1000.0);

        // Test 11: the reserved code is rejected by the controller and never
        // reaches the PLL, so the running clock is untouched
        ack_mark  = ack_count;
        request_and_abandon(INVALID, 8);
        check_int("reserved: no freq_ack", ack_count - ack_mark, 0);
        check_bit("reserved: pll_error set", pll_error, 1'b1);
        check_bit("reserved: clock still valid", clock_valid, 1'b1);
        check_bit("reserved: model never saw it", model_reject, 1'b0);
        check_level("reserved: level unchanged", current_freq_sel, HIGH);
        measure_clock;
        check_real("reserved: period undisturbed", meas_period,
                   PERIOD_HIGH_PS / 1000.0);

        // Test 12: sticky error clears on request
        pulse_err_clear;
        @(negedge clk_ref);
        check_bit("err_clear: error cleared", pll_error, 1'b0);

        // Test 13: asymmetric costs show up as different transition durations
        request_and_wait(LOW);
        request_and_wait(HIGH);
        b1 = busy_len;
        request_and_wait(LOW);
        b2 = busy_len;
        check_int("asymmetry: LOW->HIGH busy",
                  b1, RECONFIG_CYCLES + CYC_LOW_HIGH + 4);
        check_int("asymmetry: HIGH->LOW busy",
                  b2, RECONFIG_CYCLES + CYC_HIGH_LOW + 4);
        check_bit("asymmetry: upshift is longer", (b1 > b2), 1'b1);

        // Test 14: freq_sel changing mid-transition is ignored
        ack_mark = ack_count;
        @(negedge clk_ref);
        freq_sel = HIGH;
        freq_req = 1'b1;
        wait (pll_busy === 1'b1);
        repeat (3) @(negedge clk_ref);
        freq_sel = MEDIUM;
        wait (pll_done === 1'b1);
        @(negedge clk_ref);
        freq_req = 1'b0;
        wait (pll_done === 1'b0);
        @(negedge clk_ref);
        check_int("mid-change: one ack", ack_count - ack_mark, 1);
        check_level("mid-change: original target kept", current_freq_sel, HIGH);
        measure_clock;
        check_real("mid-change: HIGH period", meas_period,
                   PERIOD_HIGH_PS / 1000.0);
        freq_sel = HIGH;

        // Test 15: repeated back-to-back transitions with no idle gap
        ack_mark = ack_count;
        request_and_wait(LOW);
        request_and_wait(MEDIUM);
        request_and_wait(HIGH);
        request_and_wait(LOW);
        check_int("repeated: four acks", ack_count - ack_mark, 4);
        check_level("repeated: ends at LOW", current_freq_sel, LOW);
        check_bit("repeated: no error", pll_error, 1'b0);
        measure_clock;
        check_real("repeated: LOW period", meas_period, PERIOD_LOW_PS / 1000.0);

        // Test 16: reset asserted mid-transition, during the reconfiguration
        // strobe
        ack_mark = ack_count;
        @(negedge clk_ref);
        freq_sel = HIGH;
        freq_req = 1'b1;
        wait (pll_busy === 1'b1);
        @(negedge clk_ref);
        @(negedge clk_ref);
        rst_n = 1'b0;
        @(negedge clk_ref);
        check_bit("reset in reconfig: busy low",    pll_busy,    1'b0);
        check_bit("reset in reconfig: done low",    pll_done,    1'b0);
        check_bit("reset in reconfig: cv low",      clock_valid, 1'b0);
        check_bit("reset in reconfig: gpu_clk low", gpu_clk,     1'b0);
        check_level("reset in reconfig: reports LOW", current_freq_sel, LOW);
        check_int("reset in reconfig: no ack", ack_count - ack_mark, 0);
        freq_req = 1'b0;
        rst_n    = 1'b1;
        wait (clock_valid === 1'b1);
        @(negedge clk_ref);
        measure_clock;
        check_real("reset in reconfig: back at LOW", meas_period,
                   PERIOD_LOW_PS / 1000.0);

        // Test 17: reset asserted while the model is settling
        ack_mark = ack_count;
        @(negedge clk_ref);
        freq_sel = HIGH;
        freq_req = 1'b1;
        wait (model_lock === 1'b0);
        repeat (RECONFIG_CYCLES + 4) @(negedge clk_ref);
        check_bit("reset in settle: still busy", pll_busy, 1'b1);
        rst_n = 1'b0;
        @(negedge clk_ref);
        check_bit("reset in settle: busy low",      pll_busy,    1'b0);
        check_bit("reset in settle: cv low",        clock_valid, 1'b0);
        check_bit("reset in settle: gpu_clk low",   gpu_clk,     1'b0);
        check_int("reset in settle: no ack", ack_count - ack_mark, 0);
        freq_req = 1'b0;
        rst_n    = 1'b1;
        wait (clock_valid === 1'b1);
        @(negedge clk_ref);
        check_level("reset in settle: reports LOW", current_freq_sel, LOW);

        // Test 18: lock lost while the controller is sitting in DONE.
        // clk_run is forced alongside the lock bit so the model stays
        // self-consistent and gpu_clk really does stop.
        ack_mark = ack_count;
        @(negedge clk_ref);
        freq_sel = MEDIUM;
        freq_req = 1'b1;
        wait (pll_done === 1'b1);
        @(negedge clk_ref);
        force dut.u_pll.pll_lock_in = 1'b0;
        force dut.u_pll.clk_run = 1'b0;
        repeat (3) @(negedge clk_ref);
        check_int("lock loss in DONE: still one ack", ack_count - ack_mark, 1);
        check_bit("lock loss in DONE: done still high", pll_done, 1'b1);
        freq_req = 1'b0;
        wait (clock_valid === 1'b0);
        repeat (2) @(negedge clk_ref);
        check_bit("lock loss: clock_valid dropped", clock_valid, 1'b0);
        check_bit("lock loss: pll_error set", pll_error, 1'b1);
        // The controller can only notice a lock loss once it is back in IDLE,
        // so this lag covers the cycles spent in DONE as well as the
        // synchroniser. It is a bound, not a tight figure.
        $display("INFO: clock_valid dropped %0d cycles after lock was lost",
                 cv_fall - lk_fall);
        check_bit("lock loss: cv drop follows lock loss",
                  ((cv_fall > lk_fall) && ((cv_fall - lk_fall) <= 8)), 1'b1);
        force dut.u_pll.pll_lock_in = 1'b1;
        force dut.u_pll.clk_run = 1'b1;
        wait (clock_valid === 1'b1);
        @(negedge clk_ref);
        release dut.u_pll.pll_lock_in;
        release dut.u_pll.clk_run;
        check_bit("lock loss: recovered", clock_valid, 1'b1);
        check_int("lock loss: no extra ack", ack_count - ack_mark, 1);
        check_level("lock loss: level unchanged", current_freq_sel, MEDIUM);
        pulse_err_clear;

        // Test 19: the clock is stable over several cycles after a switch
        request_and_wait(HIGH);
        measure_clock; p1 = meas_period;
        measure_clock; p2 = meas_period;
        check_real("stable 1", p1, PERIOD_HIGH_PS / 1000.0);
        check_real("stable 2", p2, PERIOD_HIGH_PS / 1000.0);
        check_bit("stable: periods identical", (p1 == p2), 1'b1);

        $display("--- main DUT done, %0d checks so far ---", pass_count);
        run_aux_tests;

        $display("==========================");
        $display("PASS = %0d  FAIL = %0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("P1 TOP TESTS FAILED");
        $display("==========================");
        $finish;
    end

    // ---------------------------------------------------------------------
    // Parameter variants. Each has its own reset and request pins so it can
    // be driven independently of the main DUT.
    // ---------------------------------------------------------------------

    reg rst_n_rc1;
    reg freq_req_rc1;
    reg [1:0] freq_sel_rc1;
    wire pll_done_rc1;
    wire freq_ack_rc1;
    wire pll_busy_rc1;
    wire pll_error_rc1;
    wire [1:0] current_freq_sel_rc1;
    wire clock_valid_rc1;
    wire gpu_clk_rc1;

    // RECONFIG_CYCLES = 1, the degenerate single-cycle strobe
    p1_pll_top #(
        .RECONFIG_CYCLES(1),
        .LOCK_TIMEOUT(LOCK_TIMEOUT),
        .STARTUP_CYCLES(STARTUP_CYCLES)
    ) dut_rc1 (
        .clk_ref(clk_ref),
        .rst_n(rst_n_rc1),
        .freq_req(freq_req_rc1),
        .freq_sel(freq_sel_rc1),
        .err_clear(1'b0),
        .pll_done(pll_done_rc1),
        .freq_ack(freq_ack_rc1),
        .pll_busy(pll_busy_rc1),
        .pll_error(pll_error_rc1),
        .pll_locked(),
        .current_freq_sel(current_freq_sel_rc1),
        .clock_valid(clock_valid_rc1),
        .gpu_clk(gpu_clk_rc1)
    );

    reg rst_n_t0;
    reg freq_req_t0;
    reg [1:0] freq_sel_t0;
    wire pll_done_t0;
    wire pll_error_t0;
    wire [1:0] current_freq_sel_t0;
    wire clock_valid_t0;

    // LOCK_TIMEOUT = 0, the documented wait-indefinitely mode
    p1_pll_top #(
        .RECONFIG_CYCLES(RECONFIG_CYCLES),
        .LOCK_TIMEOUT(0),
        .STARTUP_CYCLES(STARTUP_CYCLES)
    ) dut_t0 (
        .clk_ref(clk_ref),
        .rst_n(rst_n_t0),
        .freq_req(freq_req_t0),
        .freq_sel(freq_sel_t0),
        .err_clear(1'b0),
        .pll_done(pll_done_t0),
        .freq_ack(),
        .pll_busy(),
        .pll_error(pll_error_t0),
        .pll_locked(),
        .current_freq_sel(current_freq_sel_t0),
        .clock_valid(clock_valid_t0),
        .gpu_clk()
    );

    reg rst_n_tto;
    reg freq_req_tto;
    reg [1:0] freq_sel_tto;
    wire pll_done_tto;
    wire pll_error_tto;
    wire [1:0] current_freq_sel_tto;
    wire clock_valid_tto;

    // LOCK_TIMEOUT deliberately too small for the LOW -> HIGH matrix entry,
    // which needs 18 + 4 cycles. This must time out, not complete.
    p1_pll_top #(
        .RECONFIG_CYCLES(RECONFIG_CYCLES),
        .LOCK_TIMEOUT(8),
        .STARTUP_CYCLES(STARTUP_CYCLES)
    ) dut_tto (
        .clk_ref(clk_ref),
        .rst_n(rst_n_tto),
        .freq_req(freq_req_tto),
        .freq_sel(freq_sel_tto),
        .err_clear(1'b0),
        .pll_done(pll_done_tto),
        .freq_ack(),
        .pll_busy(),
        .pll_error(pll_error_tto),
        .pll_locked(),
        .current_freq_sel(current_freq_sel_tto),
        .clock_valid(clock_valid_tto),
        .gpu_clk()
    );

    task run_aux_tests;
        integer i;
        begin
            // Test 20: RECONFIG_CYCLES = 1 still completes a transition
            check_bit("RECONFIG_CYCLES=1: starts unlocked",
                      clock_valid_rc1, 1'b0);
            rst_n_rc1 = 1'b1;
            wait (clock_valid_rc1 === 1'b1);
            @(negedge clk_ref);
            check_level("RECONFIG_CYCLES=1: starts at LOW",
                        current_freq_sel_rc1, LOW);
            freq_sel_rc1 = HIGH;
            freq_req_rc1 = 1'b1;
            wait (pll_done_rc1 === 1'b1);
            @(negedge clk_ref);
            freq_req_rc1 = 1'b0;
            wait (pll_done_rc1 === 1'b0);
            @(negedge clk_ref);
            check_level("RECONFIG_CYCLES=1: reaches HIGH",
                        current_freq_sel_rc1, HIGH);
            check_bit("RECONFIG_CYCLES=1: clock_valid",
                      clock_valid_rc1, 1'b1);
            check_bit("RECONFIG_CYCLES=1: no error", pll_error_rc1, 1'b0);

            // Test 21: LOCK_TIMEOUT = 0 waits indefinitely and still completes
            rst_n_t0 = 1'b1;
            wait (clock_valid_t0 === 1'b1);
            @(negedge clk_ref);
            freq_sel_t0 = HIGH;
            freq_req_t0 = 1'b1;
            wait (pll_done_t0 === 1'b1);
            @(negedge clk_ref);
            freq_req_t0 = 1'b0;
            wait (pll_done_t0 === 1'b0);
            @(negedge clk_ref);
            check_level("LOCK_TIMEOUT=0: reaches HIGH",
                        current_freq_sel_t0, HIGH);
            check_bit("LOCK_TIMEOUT=0: no error", pll_error_t0, 1'b0);
            check_bit("LOCK_TIMEOUT=0: clock_valid", clock_valid_t0, 1'b1);

            // Test 22: a LOCK_TIMEOUT smaller than the matrix entry must fail
            // the transition rather than silently complete it
            rst_n_tto = 1'b1;
            wait (clock_valid_tto === 1'b1);
            @(negedge clk_ref);
            freq_sel_tto = HIGH;
            freq_req_tto = 1'b1;
            for (i = 0; i < 60; i = i + 1)
                @(negedge clk_ref);
            check_bit("LOCK_TIMEOUT too small: error raised",
                      pll_error_tto, 1'b1);
            check_bit("LOCK_TIMEOUT too small: no completion",
                      pll_done_tto, 1'b0);
            check_level("LOCK_TIMEOUT too small: level not committed",
                        current_freq_sel_tto, LOW);
            check_bit("LOCK_TIMEOUT too small: clock_valid low",
                      clock_valid_tto, 1'b0);
            freq_req_tto = 1'b0;
            @(negedge clk_ref);
        end
    endtask

    initial begin
        rst_n_rc1    = 1'b0;
        freq_req_rc1 = 1'b0;
        freq_sel_rc1 = LOW;
        rst_n_t0     = 1'b0;
        freq_req_t0  = 1'b0;
        freq_sel_t0  = LOW;
        rst_n_tto    = 1'b0;
        freq_req_tto = 1'b0;
        freq_sel_tto = LOW;
    end

    initial begin
        #200000;
        $display("FAIL: watchdog expired in tb_p1_pll_top");
        $finish;
    end

endmodule
