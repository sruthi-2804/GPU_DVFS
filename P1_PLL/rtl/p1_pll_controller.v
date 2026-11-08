`timescale 1ns / 1ps

// P1 frequency transition controller.
//
// Accepts a frequency request from P3, drives a reconfiguration sequence at a
// behavioral PLL, waits for lock and reports completion. Synthesizable control
// logic only: this module contains no clock generation. The GPU clock is
// produced by the behavioral clock model added in Session 2, which consumes
// pll_reconfig_en / pll_freq_code and returns pll_lock_in.
//
// All state lives on clk_ref. pll_lock_in is treated as asynchronous and is
// passed through a two-flop synchroniser before it is used.

module p1_pll_controller #(
    // Cycles the reconfiguration strobe is held at the PLL. Must be >= 1.
    parameter integer RECONFIG_CYCLES = 4,

    // clk_ref cycles to wait for lock before declaring an error.
    // 0 disables the timeout and waits indefinitely. Must be < 65536.
    parameter integer LOCK_TIMEOUT = 1024
)(
    // Control domain
    input wire clk_ref,
    input wire rst_n,

    // Frequency request from P3
    input wire freq_req,
    input wire [1:0] freq_sel,

    // Sticky error clear, from PMU or software
    input wire err_clear,

    // Handshake back to P3
    output reg freq_ack,
    output reg pll_done,
    output reg pll_busy,
    output reg pll_error,

    // Status
    output reg pll_locked,
    output reg [1:0] current_freq_sel,
    output reg clock_valid,

    // To and from the behavioral PLL model (Session 2)
    output reg pll_reconfig_en,
    output reg [1:0] pll_freq_code,
    input wire pll_lock_in
);

    // Shared performance-level encoding, same as P2/P3/P4
    localparam [1:0]
        LEVEL_LOW     = 2'b00,
        LEVEL_MEDIUM  = 2'b01,
        LEVEL_HIGH    = 2'b10,
        LEVEL_INVALID = 2'b11;

    // FSM state encoding
    localparam [2:0]
        IDLE      = 3'd0,
        ACCEPT    = 3'd1,
        RECONFIG  = 3'd2,
        LOCK_WAIT = 3'd3,
        DONE      = 3'd4,
        ERROR     = 3'd5;

    reg [2:0] state;
    reg [2:0] next_state;

    // Latched request
    reg [1:0] target_sel;
    reg req_pending;

    // Dwell counter, reused by RECONFIG and LOCK_WAIT
    reg [15:0] wait_count;

    // Two-flop synchroniser for the PLL lock input
    reg lock_meta;
    reg lock_sync;

    // Lock lost while the generated clock was in use
    wire lock_lost = (state == IDLE) && clock_valid && !lock_sync;

    // Lock did not arrive in time. Guarded so LOCK_TIMEOUT = 0 never expires.
    wire timeout_hit = (LOCK_TIMEOUT != 0) &&
                       (wait_count >= LOCK_TIMEOUT - 1);

    // Lock established at the code the PLL is actually running
    wire lock_matches_report = lock_sync &&
                               (pll_freq_code == current_freq_sel);

    // Synchronise the asynchronous lock input into clk_ref
    always @(posedge clk_ref or negedge rst_n) begin
        if (!rst_n) begin
            lock_meta <= 1'b0;
            lock_sync <= 1'b0;
        end
        else begin
            lock_meta <= pll_lock_in;
            lock_sync <= lock_meta;
        end
    end

    // Sequential state and datapath
    always @(posedge clk_ref or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            target_sel       <= LEVEL_LOW;
            req_pending      <= 1'b0;
            wait_count       <= 16'd0;
            freq_ack         <= 1'b0;
            pll_error        <= 1'b0;
            current_freq_sel <= LEVEL_LOW;
            clock_valid      <= 1'b0;
            pll_freq_code    <= LEVEL_LOW;
        end
        else begin
            state <= next_state;

            // Latch a valid request. freq_sel is ignored from here until the
            // transition completes, so a request cannot change mid-flight.
            if (state == IDLE && freq_req && freq_sel != LEVEL_INVALID) begin
                target_sel  <= freq_sel;
                req_pending <= 1'b1;
            end
            else if (state == DONE || state == ERROR) begin
                req_pending <= 1'b0;
            end

            // Hand the new code to the PLL only when it really changes
            if (state == ACCEPT && next_state == RECONFIG)
                pll_freq_code <= target_sel;

            // Restart the dwell counter on every state entry
            if (next_state != state)
                wait_count <= 16'd0;
            else if (state == RECONFIG || state == LOCK_WAIT)
                wait_count <= wait_count + 16'd1;

            // One acknowledgement pulse per request, on entry to DONE
            freq_ack <= (next_state == DONE) && (state != DONE);

            // Commit the new operating point
            if (state == DONE)
                current_freq_sel <= target_sel;

            // Generated clock usability
            if (state == ACCEPT && next_state == RECONFIG)
                clock_valid <= 1'b0;
            else if (lock_lost)
                clock_valid <= 1'b0;
            else if (state == DONE)
                clock_valid <= 1'b1;
            else if (state == IDLE && !clock_valid && lock_matches_report)
                clock_valid <= 1'b1;

            // Sticky error. A set in the same cycle wins over a clear.
            if (err_clear)
                pll_error <= 1'b0;
            if (lock_lost || (next_state == ERROR && state != ERROR))
                pll_error <= 1'b1;
        end
    end

    // Combinational next-state logic
    always @(*) begin
        next_state = state;

        case (state)

            IDLE: begin
                if (freq_req) begin
                    if (freq_sel == LEVEL_INVALID)
                        next_state = ERROR;
                    else
                        next_state = ACCEPT;
                end
                else if (lock_lost) begin
                    next_state = LOCK_WAIT;
                end
            end

            ACCEPT: begin
                // A request for the running frequency is acknowledged without
                // touching the PLL
                if (target_sel == current_freq_sel && clock_valid)
                    next_state = DONE;
                else
                    next_state = RECONFIG;
            end

            RECONFIG: begin
                if (wait_count >= RECONFIG_CYCLES - 1)
                    next_state = LOCK_WAIT;
            end

            LOCK_WAIT: begin
                if (lock_sync) begin
                    // Relock after a lock loss finishes silently
                    if (req_pending)
                        next_state = DONE;
                    else
                        next_state = IDLE;
                end
                else if (timeout_hit) begin
                    next_state = ERROR;
                end
            end

            DONE: begin
                // Hold the acknowledgement until P3 releases its request
                if (!freq_req)
                    next_state = IDLE;
            end

            ERROR: begin
                if (!freq_req)
                    next_state = IDLE;
            end

            default: begin
                next_state = IDLE;
            end

        endcase
    end

    // Combinational status outputs decoded from the state
    always @(*) begin
        pll_busy        = 1'b0;
        pll_done        = 1'b0;
        pll_reconfig_en = 1'b0;
        pll_locked      = lock_sync;

        case (state)

            ACCEPT: begin
                pll_busy = 1'b1;
            end

            RECONFIG: begin
                pll_busy        = 1'b1;
                pll_reconfig_en = 1'b1;
            end

            LOCK_WAIT: begin
                pll_busy = 1'b1;
            end

            DONE: begin
                pll_done = 1'b1;
            end

            default: begin
                pll_busy = 1'b0;
            end

        endcase
    end

endmodule
