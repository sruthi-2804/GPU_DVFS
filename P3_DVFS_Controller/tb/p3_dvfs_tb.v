`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: p3_dvfs_tb
// Description: Testbench for p3_dvfs_controller.
//              Handshake responders are clocked and level-sensitive so that
//              their scheduling does not race with the DUT's combinational
//              request outputs.
//////////////////////////////////////////////////////////////////////////////////
module p3_dvfs_tb;

reg clk;
reg rst_n;

reg [1:0] requested_level;
reg pll_done;
reg volt_done;

wire pll_req;
wire [1:0] pll_freq_sel;

wire volt_req;
wire [1:0] volt_level;
wire [1:0] current_level;

// Handshake latency, in clock cycles
localparam integer ACK_LATENCY = 3;

// Instantiate P3 controller
    p3_dvfs_controller dut (
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

// Clock period = 10 ns
    initial clk = 1'b0;
    always #5 clk = ~clk;

// Simulated P1 PLL response.
// Level-sensitive and clocked: assert pll_done ACK_LATENCY cycles after
// pll_req goes high, drop it once pll_req is released.
    integer pll_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pll_done <= 1'b0;
            pll_cnt  <= 0;
        end
        else if (!pll_req) begin
            pll_done <= 1'b0;
            pll_cnt  <= 0;
        end
        else if (!pll_done) begin
            if (pll_cnt >= ACK_LATENCY - 1)
                pll_done <= 1'b1;
            else
                pll_cnt <= pll_cnt + 1;
        end
    end

// Simulated P4 voltage response
    integer volt_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            volt_done <= 1'b0;
            volt_cnt  <= 0;
        end
        else if (!volt_req) begin
            volt_done <= 1'b0;
            volt_cnt  <= 0;
        end
        else if (!volt_done) begin
            if (volt_cnt >= ACK_LATENCY - 1)
                volt_done <= 1'b1;
            else
                volt_cnt <= volt_cnt + 1;
        end
    end

// Safety check: never request both together
    always @(posedge clk) begin
        if (rst_n && pll_req && volt_req)
            $fatal(1, "ERROR: Both requests active!");
    end

// Check a complete performance transition
    task run_change;
        input [1:0] new_level;
        input integer increasing;
        begin
            @(negedge clk);
            requested_level = new_level;

            $display("Time %0t: Request level %b", $time, new_level);

            if (increasing) begin
                // Voltage must be requested first
                wait (volt_req == 1'b1);
                if (pll_req)
                    $fatal(1, "PLL requested too early");

                if (volt_level != new_level)
                    $fatal(1, "Wrong voltage level");

                $display("Voltage requested first");

                wait (pll_req == 1'b1);
                if (volt_req)
                    $fatal(1, "Voltage request still active");

                if (pll_freq_sel != new_level)
                    $fatal(1, "Wrong PLL level");

                $display("Frequency requested second");
            end
            else begin
                // Frequency must be requested first
                wait (pll_req == 1'b1);
                if (volt_req)
                    $fatal(1, "Voltage requested too early");

                if (pll_freq_sel != new_level)
                    $fatal(1, "Wrong PLL level");

                $display("Frequency requested first");

                wait (volt_req == 1'b1);
                if (pll_req)
                    $fatal(1, "PLL request still active");

                if (volt_level != new_level)
                    $fatal(1, "Wrong voltage level");

                $display("Voltage requested second");
            end

            // Controller must finish the change
            wait (current_level == new_level);
            @(negedge clk);

            if (pll_req || volt_req)
                $fatal(1, "Request active after completion");

            $display("PASS: Current level = %b", current_level);
        end
    endtask

// Main test sequence
    initial begin
        rst_n = 1'b0;
        requested_level = 2'b00;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // LOW -> HIGH
        run_change(2'b10, 1);

        // HIGH -> LOW
        run_change(2'b00, 0);

        // LOW -> MEDIUM
        run_change(2'b01, 1);

        // MEDIUM -> HIGH
        run_change(2'b10, 1);

        $display("==========================");
        $display("ALL BASIC DVFS TESTS PASSED");
        $display("==========================");

        $finish;
    end

// Timeout protection
    initial begin
        #5000;
        $fatal(1, "ERROR: Simulation timeout");
    end

endmodule
