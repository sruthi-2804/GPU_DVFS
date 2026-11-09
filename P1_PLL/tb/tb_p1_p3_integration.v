`timescale 1ns / 1ps

// P3 to P1 integration tests.
//
// p3_dvfs_controller and p1_pll_top are wired together with no change to P3:
//   P3 pll_req      -> P1 freq_req
//   P3 pll_freq_sel -> P1 freq_sel
//   P1 pll_done     -> P3 pll_done
// Both run on the same clk and rst_n, which is the assumption P3's own
// interface document records. P4 is a clocked, level-sensitive stand-in, the
// same convention P3's own testbench uses.
//
// Expected pll_req high time for one frequency change, in clk_ref cycles:
//   RECONFIG_CYCLES + settle_cycles + 6
// Two more than P1's own pll_busy time of RECONFIG_CYCLES + settle_cycles + 4:
// one cycle at the start for P1 to sample the request, and one at the end for
// P3 to sample pll_done. Both are measured, not assumed.
//
// SECOND INSTANCE, KNOWN DEFECT: dut3_dl / dut1_dl reproduce the deadlock
// recorded in Session 1. Its checks assert that the system really does hang,
// so they pass while the defect is present and will fail the day P3 gains a
// way out. Read the banner this testbench prints at the end.

module tb_p1_p3_integration;

    localparam CLK_PERIOD = 10;
    localparam RECONFIG_CYCLES = 4;
    localparam VOLT_LATENCY = 3;

    localparam CYC_LOW_MED = 10;
    localparam CYC_LOW_HIGH = 18;
    localparam CYC_MED_HIGH = 12;
    localparam CYC_HIGH_LOW = 14;

    localparam PERIOD_LOW_PS = 20000;
    localparam PERIOD_MED_PS = 10000;
    localparam PERIOD_HIGH_PS = 5000;

    localparam real TOL_NS = 0.01;

    localparam [1:0]
        LOW    = 2'b00,
        MEDIUM = 2'b01,
        HIGH   = 2'b10;

    // P3 FSM state encoding, for the deadlock probe
    localparam [2:0] P3_FREQUENCY_CHANGE = 3'd3;

    reg clk;
    reg rst_n;
    reg [1:0] requested_level;

    // P3 outputs
    wire pll_req;
    wire [1:0] pll_freq_sel;
    wire volt_req;
    wire [1:0] volt_level;
    wire [1:0] current_level;

    // P1 outputs
    wire pll_done;
    wire freq_ack;
    wire pll_busy;
    wire pll_error;
    wire pll_locked;
    wire [1:0] current_freq_sel;
    wire clock_valid;
    wire gpu_clk;

    reg volt_done;

    integer pass_count = 0;
    integer fail_count = 0;

    integer cyc_count = 0;
    integer ack_count = 0;

    reg req_q;
    reg ack_q;
    reg [1:0] level_q;
    integer req_start;
    integer req_len;
    integer ack_cycle;
    integer level_cycle;

    real meas_period;

    p3_dvfs_controller p3 (
        .clk(clk),
        .rst_n(rst_n),
        .requested_level(requested_level),
        .pll_done(pll_done),
        .volt_done(volt_done),
        .pll_req(pll_req),
        .pll_freq_sel(pll_freq_sel),
        .volt_req(volt_req),
        .volt_level(volt_level),
        .current_level(current_level)
    );

    p1_pll_top #(
        .RECONFIG_CYCLES(RECONFIG_CYCLES),
        .LOCK_TIMEOUT(1024),
        .PERIOD_LOW_PS(PERIOD_LOW_PS),
        .PERIOD_MED_PS(PERIOD_MED_PS),
        .PERIOD_HIGH_PS(PERIOD_HIGH_PS),
        .STARTUP_CYCLES(20)
    ) p1 (
        .clk_ref(clk),
        .rst_n(rst_n),
        .freq_req(pll_req),
        .freq_sel(pll_freq_sel),
        .err_clear(1'b0),
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
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // P4 stand-in: clocked and level-sensitive, not edge-triggered on the
    // request, so it cannot race P3's combinational outputs.
    reg [3:0] volt_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            volt_done <= 1'b0;
            volt_cnt  <= 4'd0;
        end
        else if (volt_req) begin
            if (!volt_done) begin
                if (volt_cnt >= VOLT_LATENCY - 1)
                    volt_done <= 1'b1;
                else
                    volt_cnt <= volt_cnt + 4'd1;
            end
        end
        else begin
            volt_done <= 1'b0;
            volt_cnt  <= 4'd0;
        end
    end

    always @(posedge clk) begin
        cyc_count = cyc_count + 1;

        // The two blocks must never both be driving a change
        if (volt_req === 1'b1 && pll_req === 1'b1) begin
            fail_count = fail_count + 1;
            $display("FAIL: volt_req and pll_req both high at %0t", $time);
        end

        if (freq_ack === 1'b1) begin
            ack_count = ack_count + 1;
            ack_cycle = cyc_count;
            if (ack_q === 1'b1) begin
                fail_count = fail_count + 1;
                $display("FAIL: duplicate freq_ack at %0t", $time);
            end
        end
        ack_q = freq_ack;

        if (pll_req === 1'b1 && req_q === 1'b0)
            req_start = cyc_count;
        else if (pll_req === 1'b0 && req_q === 1'b1)
            req_len = cyc_count - req_start;
        req_q = pll_req;

        if (current_level !== level_q) begin
            level_cycle = cyc_count;
            level_q = current_level;
        end
    end

    // The request P1 sees must be exactly what P3 drives
    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            if (p1.freq_req !== pll_req) begin
                fail_count = fail_count + 1;
                $display("FAIL: freq_req does not follow pll_req at %0t", $time);
            end
            if (p1.freq_sel !== pll_freq_sel) begin
                fail_count = fail_count + 1;
                $display("FAIL: freq_sel does not follow pll_freq_sel at %0t",
                         $time);
            end
            if (p3.pll_done !== pll_done) begin
                fail_count = fail_count + 1;
                $display("FAIL: pll_done does not reach P3 at %0t", $time);
            end
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
        begin
            @(posedge gpu_clk);
            t1 = $realtime;
            @(posedge gpu_clk);
            t2 = $realtime;
            meas_period = t2 - t1;
        end
    endtask

    // Drive one P3 level change and check the whole chain
    task run_level_change;
        input [319:0] name;
        input [1:0] level;
        input integer exp_settle;
        input real exp_period_ns;
        integer ack_mark;
        begin
            ack_mark = ack_count;
            @(negedge clk);
            requested_level = level;
            wait (current_level === level);
            repeat (3) @(negedge clk);

            check_int({name, " one P1 ack"}, ack_count - ack_mark, 1);
            check_int({name, " pll_req high cycles"}, req_len,
                      RECONFIG_CYCLES + exp_settle + 6);
            check_level({name, " P1 reports target"}, current_freq_sel, level);
            check_level({name, " P3 reports target"}, current_level, level);
            check_bit({name, " clock_valid"}, clock_valid, 1'b1);
            check_bit({name, " no P1 error"}, pll_error, 1'b0);
            // P3 must not commit before P1 acknowledges
            check_bit({name, " no premature completion"},
                      (level_cycle >= ack_cycle), 1'b1);
            measure_clock;
            check_real({name, " gpu_clk period"}, meas_period, exp_period_ns);
        end
    endtask

    integer ack_mark;
    reg volt_first;
    reg freq_first;

    initial begin
        $display("=== P1 / P3 INTEGRATION TEST START ===");

        rst_n           = 1'b0;
        requested_level = LOW;
        req_q           = 1'b0;
        ack_q           = 1'b0;
        level_q         = 2'b00;
        ack_cycle       = 0;
        level_cycle     = 0;

        repeat (4) @(negedge clk);

        // Test 1: both blocks start quiet
        check_bit("reset: pll_req low",     pll_req,     1'b0);
        check_bit("reset: volt_req low",    volt_req,    1'b0);
        check_bit("reset: pll_done low",    pll_done,    1'b0);
        check_bit("reset: clock_valid low", clock_valid, 1'b0);
        check_level("reset: P3 at LOW", current_level,    LOW);
        check_level("reset: P1 at LOW", current_freq_sel, LOW);

        // Test 2: P1 brings the clock up on its own, with no P3 request
        ack_mark = ack_count;
        rst_n = 1'b1;
        wait (clock_valid === 1'b1);
        repeat (2) @(negedge clk);
        check_int("startup: no P1 ack", ack_count - ack_mark, 0);
        check_bit("startup: P3 made no request", pll_req, 1'b0);
        measure_clock;
        check_real("startup: LOW period", meas_period, PERIOD_LOW_PS / 1000.0);

        // Test 3: upshift LOW to HIGH. P3 must raise voltage before frequency.
        @(negedge clk);
        requested_level = HIGH;
        wait (volt_req === 1'b1 || pll_req === 1'b1);
        volt_first = (volt_req === 1'b1);
        check_bit("upshift: voltage requested first", volt_first, 1'b1);
        wait (current_level === HIGH);
        repeat (3) @(negedge clk);
        check_int("upshift: one P1 ack", ack_count, 1);
        check_int("upshift: pll_req high cycles", req_len,
                  RECONFIG_CYCLES + CYC_LOW_HIGH + 6);
        check_level("upshift: P1 at HIGH", current_freq_sel, HIGH);
        check_level("upshift: P3 at HIGH", current_level, HIGH);
        check_bit("upshift: no premature completion",
                  (level_cycle >= ack_cycle), 1'b1);
        measure_clock;
        check_real("upshift: HIGH period", meas_period, PERIOD_HIGH_PS / 1000.0);

        // Test 4: downshift HIGH to LOW. Frequency must drop before voltage.
        @(negedge clk);
        requested_level = LOW;
        wait (volt_req === 1'b1 || pll_req === 1'b1);
        freq_first = (pll_req === 1'b1);
        check_bit("downshift: frequency requested first", freq_first, 1'b1);
        wait (current_level === LOW);
        repeat (3) @(negedge clk);
        check_int("downshift: pll_req high cycles", req_len,
                  RECONFIG_CYCLES + CYC_HIGH_LOW + 6);
        check_level("downshift: P1 at LOW", current_freq_sel, LOW);
        measure_clock;
        check_real("downshift: LOW period", meas_period, PERIOD_LOW_PS / 1000.0);

        // Test 5: adjacent-level changes through the same path
        run_level_change("LOW->MED", MEDIUM, CYC_LOW_MED,
                         PERIOD_MED_PS / 1000.0);
        run_level_change("MED->HIGH", HIGH, CYC_MED_HIGH,
                         PERIOD_HIGH_PS / 1000.0);

        // Test 6: the same sequence twice over gives identical timing, which is
        // what the shared-clock assumption buys. A crossing would not be
        // repeatable like this.
        @(negedge clk);
        requested_level = LOW;
        wait (current_level === LOW);
        repeat (3) @(negedge clk);
        check_int("repeat: HIGH->LOW cycles again", req_len,
                  RECONFIG_CYCLES + CYC_HIGH_LOW + 6);
        run_level_change("repeat LOW->MED", MEDIUM, CYC_LOW_MED,
                         PERIOD_MED_PS / 1000.0);

        // Test 7: one P1 transition per P3 level change, no duplicates
        check_int("total P1 acks for six level changes", ack_count, 6);

        run_deadlock_test;

        $display("==========================");
        $display("PASS = %0d  FAIL = %0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("P1/P3 INTEGRATION TESTS FAILED");
        $display("==========================");
        $display("");
        $display("KNOWN DEFECT: P1 ERROR deadlocks P3. See test 8 above and");
        $display("docs/p1_pll_characterization.md. P3/P1 integration is NOT");
        $display("complete while this is open.");
        $display("");
        $finish;
    end

    // ---------------------------------------------------------------------
    // Test 8, the known deadlock.
    //
    // A second P3/P1 pair, with P1's LOCK_TIMEOUT set below what the matrix
    // needs, so the frequency change cannot succeed. P1 enters ERROR and waits
    // for freq_req to fall. P3 sits in FREQUENCY_CHANGE holding pll_req and
    // waits for pll_done. Neither moves again.
    //
    // These checks assert the hang, so they pass while the defect exists.
    // ---------------------------------------------------------------------

    reg rst_n_dl;
    reg [1:0] requested_level_dl;

    wire pll_req_dl;
    wire [1:0] pll_freq_sel_dl;
    wire volt_req_dl;
    wire [1:0] volt_level_dl;
    wire [1:0] current_level_dl;
    wire pll_done_dl;
    wire freq_ack_dl;
    wire pll_error_dl;
    wire clock_valid_dl;

    reg volt_done_dl;
    reg [3:0] volt_cnt_dl;

    p3_dvfs_controller p3_dl (
        .clk(clk),
        .rst_n(rst_n_dl),
        .requested_level(requested_level_dl),
        .pll_done(pll_done_dl),
        .volt_done(volt_done_dl),
        .pll_req(pll_req_dl),
        .pll_freq_sel(pll_freq_sel_dl),
        .volt_req(volt_req_dl),
        .volt_level(volt_level_dl),
        .current_level(current_level_dl)
    );

    p1_pll_top #(
        .RECONFIG_CYCLES(RECONFIG_CYCLES),
        .LOCK_TIMEOUT(8),
        .STARTUP_CYCLES(20)
    ) p1_dl (
        .clk_ref(clk),
        .rst_n(rst_n_dl),
        .freq_req(pll_req_dl),
        .freq_sel(pll_freq_sel_dl),
        .err_clear(1'b0),
        .pll_done(pll_done_dl),
        .freq_ack(freq_ack_dl),
        .pll_busy(),
        .pll_error(pll_error_dl),
        .pll_locked(),
        .current_freq_sel(),
        .clock_valid(clock_valid_dl),
        .gpu_clk()
    );

    always @(posedge clk or negedge rst_n_dl) begin
        if (!rst_n_dl) begin
            volt_done_dl <= 1'b0;
            volt_cnt_dl  <= 4'd0;
        end
        else if (volt_req_dl) begin
            if (!volt_done_dl) begin
                if (volt_cnt_dl >= VOLT_LATENCY - 1)
                    volt_done_dl <= 1'b1;
                else
                    volt_cnt_dl <= volt_cnt_dl + 4'd1;
            end
        end
        else begin
            volt_done_dl <= 1'b0;
            volt_cnt_dl  <= 4'd0;
        end
    end

    integer ack_dl_count = 0;

    always @(posedge clk) begin
        if (freq_ack_dl === 1'b1)
            ack_dl_count = ack_dl_count + 1;
    end

    task run_deadlock_test;
        begin
            $display("--- Test 8: known P1/P3 deadlock, expected to hang ---");

            rst_n_dl = 1'b1;
            wait (clock_valid_dl === 1'b1);
            repeat (2) @(negedge clk);

            @(negedge clk);
            requested_level_dl = HIGH;

            // Wait for P1 to give up on the frequency change
            wait (pll_error_dl === 1'b1);
            repeat (4) @(negedge clk);

            check_bit("deadlock: P1 raised pll_error", pll_error_dl, 1'b1);
            check_bit("deadlock: P1 never acknowledged", pll_done_dl, 1'b0);
            check_int("deadlock: no freq_ack issued", ack_dl_count, 0);
            check_bit("deadlock: P3 still asserting pll_req",
                      pll_req_dl, 1'b1);
            check_bit("deadlock: P3 stuck in FREQUENCY_CHANGE",
                      (p3_dl.state === P3_FREQUENCY_CHANGE), 1'b1);
            check_level("deadlock: P3 level not committed",
                        current_level_dl, LOW);

            // Still stuck a long time later, so this is a hang and not just
            // slow progress
            repeat (300) @(negedge clk);
            check_bit("deadlock: still stuck after 300 cycles",
                      (p3_dl.state === P3_FREQUENCY_CHANGE) &&
                      (pll_req_dl === 1'b1) &&
                      (pll_done_dl === 1'b0), 1'b1);
            check_level("deadlock: P3 level still not committed",
                        current_level_dl, LOW);
            check_bit("deadlock: GPU clock left unusable",
                      clock_valid_dl, 1'b0);

            // Only a reset breaks it, which is the point
            rst_n_dl = 1'b0;
            repeat (2) @(negedge clk);
            check_bit("deadlock: reset clears P3 request", pll_req_dl, 1'b0);
            check_bit("deadlock: reset clears P1 error", pll_error_dl, 1'b0);
        end
    endtask

    initial begin
        rst_n_dl           = 1'b0;
        requested_level_dl = LOW;
        volt_cnt_dl        = 4'd0;
    end

    initial begin
        #300000;
        $display("FAIL: watchdog expired in tb_p1_p3_integration");
        $finish;
    end

endmodule
