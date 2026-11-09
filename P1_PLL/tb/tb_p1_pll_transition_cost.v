`timescale 1ns / 1ps

// Directed tests for the P1 transition-cost matrix.
//
// Two instances share the index inputs: one at the default illustrative
// matrix, one with calibration-style overrides that exercise ceiling rounding,
// a non-zero same-state cost and the energy field.

module tb_p1_pll_transition_cost;

    localparam [1:0]
        LOW     = 2'b00,
        MEDIUM  = 2'b01,
        HIGH    = 2'b10,
        INVALID = 2'b11;

    reg [1:0] from_sel;
    reg [1:0] to_sel;

    wire [31:0] settle_ps;
    wire [15:0] settle_cycles;
    wire [31:0] energy_fj;
    wire cost_valid;

    wire [31:0] cal_settle_ps;
    wire [15:0] cal_settle_cycles;
    wire [31:0] cal_energy_fj;
    wire cal_cost_valid;

    integer pass_count = 0;
    integer fail_count = 0;

    // Default illustrative matrix
    p1_pll_transition_cost dut (
        .from_sel(from_sel),
        .to_sel(to_sel),
        .settle_ps(settle_ps),
        .settle_cycles(settle_cycles),
        .energy_fj(energy_fj),
        .cost_valid(cost_valid)
    );

    // Calibration-style overrides.
    // 100001 ps and 5000 ps are not whole multiples of the 10000 ps control
    // period, so they test the ceiling rule. LOW -> LOW is deliberately
    // non-zero to show same-state cost is configurable, not hard-wired.
    p1_pll_transition_cost #(
        .CLK_REF_PERIOD_PS(10000),
        .SETTLE_LOW_LOW_PS(15000),
        .SETTLE_LOW_MED_PS(100001),
        .SETTLE_MED_HIGH_PS(5000),
        .ENERGY_LOW_MED_FJ(777),
        .ENERGY_MED_HIGH_FJ(1234)
    ) dut_cal (
        .from_sel(from_sel),
        .to_sel(to_sel),
        .settle_ps(cal_settle_ps),
        .settle_cycles(cal_settle_cycles),
        .energy_fj(cal_energy_fj),
        .cost_valid(cal_cost_valid)
    );

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

    // Check one entry of the default matrix
    task check_entry;
        input [319:0] name;
        input [1:0] f;
        input [1:0] t;
        input integer exp_ps;
        input integer exp_cyc;
        begin
            from_sel = f;
            to_sel   = t;
            #1;
            check_int({name, " ps"},     settle_ps,     exp_ps);
            check_int({name, " cycles"}, settle_cycles, exp_cyc);
            check_bit({name, " valid"},  cost_valid,    1'b1);
            check_int({name, " energy"}, energy_fj,     0);
        end
    endtask

    task check_invalid;
        input [319:0] name;
        input [1:0] f;
        input [1:0] t;
        begin
            from_sel = f;
            to_sel   = t;
            #1;
            check_bit({name, " rejected"}, cost_valid,    1'b0);
            check_int({name, " ps"},       settle_ps,     0);
            check_int({name, " cycles"},   settle_cycles, 0);
            check_int({name, " energy"},   energy_fj,     0);
        end
    endtask

    integer ps_low_high;
    integer ps_high_low;
    integer ps_low_med;
    integer ps_med_low;
    integer ps_med_high;
    integer ps_high_med;

    initial begin
        $display("=== P1 TRANSITION COST TEST START ===");

        from_sel = LOW;
        to_sel   = LOW;
        #1;

        // Test 1: all nine directed entries of the default matrix
        check_entry("LOW -> LOW",      LOW,    LOW,         0,  0);
        check_entry("LOW -> MEDIUM",   LOW,    MEDIUM, 100000, 10);
        check_entry("LOW -> HIGH",     LOW,    HIGH,   180000, 18);
        check_entry("MEDIUM -> LOW",   MEDIUM, LOW,     80000,  8);
        check_entry("MEDIUM -> MEDIUM",MEDIUM, MEDIUM,      0,  0);
        check_entry("MEDIUM -> HIGH",  MEDIUM, HIGH,   120000, 12);
        check_entry("HIGH -> LOW",     HIGH,   LOW,    140000, 14);
        check_entry("HIGH -> MEDIUM",  HIGH,   MEDIUM,  90000,  9);
        check_entry("HIGH -> HIGH",    HIGH,   HIGH,        0,  0);

        // Test 2: every index combination involving the reserved code
        check_invalid("INVALID -> LOW",     INVALID, LOW);
        check_invalid("INVALID -> MEDIUM",  INVALID, MEDIUM);
        check_invalid("INVALID -> HIGH",    INVALID, HIGH);
        check_invalid("INVALID -> INVALID", INVALID, INVALID);
        check_invalid("LOW -> INVALID",     LOW,     INVALID);
        check_invalid("MEDIUM -> INVALID",  MEDIUM,  INVALID);
        check_invalid("HIGH -> INVALID",    HIGH,    INVALID);

        // Test 3: the matrix is directed, so opposite directions differ
        from_sel = LOW;    to_sel = HIGH;   #1; ps_low_high = settle_ps;
        from_sel = HIGH;   to_sel = LOW;    #1; ps_high_low = settle_ps;
        from_sel = LOW;    to_sel = MEDIUM; #1; ps_low_med  = settle_ps;
        from_sel = MEDIUM; to_sel = LOW;    #1; ps_med_low  = settle_ps;
        from_sel = MEDIUM; to_sel = HIGH;   #1; ps_med_high = settle_ps;
        from_sel = HIGH;   to_sel = MEDIUM; #1; ps_high_med = settle_ps;

        check_bit("asymmetric LOW/HIGH pair",
                  (ps_low_high != ps_high_low), 1'b1);
        check_bit("asymmetric LOW/MEDIUM pair",
                  (ps_low_med != ps_med_low), 1'b1);
        check_bit("asymmetric MEDIUM/HIGH pair",
                  (ps_med_high != ps_high_med), 1'b1);
        check_bit("upward costs exceed downward",
                  (ps_low_high > ps_high_low) &&
                  (ps_low_med  > ps_med_low) &&
                  (ps_med_high > ps_high_med), 1'b1);

        // Test 4: ceiling rounding on the calibrated instance.
        // 100001 ps over a 10000 ps control period is 10.0001 cycles, so the
        // model must wait 11, never 10.
        from_sel = LOW; to_sel = MEDIUM; #1;
        check_int("cal LOW -> MEDIUM ps",     cal_settle_ps,     100001);
        check_int("cal LOW -> MEDIUM ceil",   cal_settle_cycles, 11);
        check_int("cal LOW -> MEDIUM energy", cal_energy_fj,     777);

        from_sel = MEDIUM; to_sel = HIGH; #1;
        check_int("cal MEDIUM -> HIGH ps",     cal_settle_ps,     5000);
        check_int("cal MEDIUM -> HIGH ceil",   cal_settle_cycles, 1);
        check_int("cal MEDIUM -> HIGH energy", cal_energy_fj,     1234);

        // Test 5: same-state cost is configurable, not forced to zero
        from_sel = LOW; to_sel = LOW; #1;
        check_int("cal LOW -> LOW ps",     cal_settle_ps,     15000);
        check_int("cal LOW -> LOW ceil",   cal_settle_cycles, 2);
        check_int("default LOW -> LOW ps", settle_ps,         0);

        // Test 6: an unspecified entry keeps its default on the calibrated
        // instance, so a partial calibration does not disturb the rest
        from_sel = HIGH; to_sel = LOW; #1;
        check_int("cal HIGH -> LOW untouched", cal_settle_ps, 140000);
        check_int("cal HIGH -> LOW cycles",    cal_settle_cycles, 14);

        $display("==========================");
        $display("PASS = %0d  FAIL = %0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TRANSITION COST TESTS FAILED");
        $display("==========================");
        $finish;
    end

endmodule
