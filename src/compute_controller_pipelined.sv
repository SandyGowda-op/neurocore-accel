//==============================================================================
// compute_controller_pipelined : drop-in replacement for compute_controller
//   Same ports/parameters. Replaces the 4-cycles-per-MAC FSM with a pipeline:
//   one scratchpad read pair issued EVERY cycle, MAC executed 2 cycles later
//   (scratchpad_bank compute read latency = 2: en in cycle t -> rdata in t+2).
//   Per output element: 1 clear slot + K MAC slots  -> (K+1) cycles/output.
//   Token sequence: CLEAR, MAC x K, CLEAR(+capture prev), MAC x K, ... CLEAR(+capture last)
//   Assumes k_size >= 1 (the DFU rejects k == 0 as an invalid descriptor).
//   Assumes mac_unit: accumulator updates at the edge ending an enable cycle, and
//   clear_acc / enable are never asserted in the same cycle (true here).
//==============================================================================
`timescale 1ns/1ps
`default_nettype none
module compute_controller_pipelined #(
    parameter int DATA_WIDTH = 32,
    parameter int ACC_WIDTH  = 64,
    parameter int ADDR_WIDTH = 6
)(
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [ADDR_WIDTH-1:0] base_addr_a,
    input  logic [ADDR_WIDTH-1:0] base_addr_b,
    input  logic [15:0] stride_a,
    input  logic [15:0] stride_b,
    input  logic [15:0] rows,
    input  logic [15:0] cols,
    input  logic [15:0] k_size,
    output logic busy,
    output logic done,
    output logic                  spad_a_en,
    output logic [ADDR_WIDTH-1:0] spad_a_addr,
    input  logic [DATA_WIDTH-1:0] spad_a_rdata,
    output logic                  spad_b_en,
    output logic [ADDR_WIDTH-1:0] spad_b_addr,
    input  logic [DATA_WIDTH-1:0] spad_b_rdata,
    output logic                  result_valid,
    output logic [15:0]           result_row,
    output logic [15:0]           result_col,
    output logic signed [ACC_WIDTH-1:0] result_data,
    output logic [31:0] cycle_count,
    output logic [31:0] a_read_count,
    output logic [31:0] b_read_count,
    output logic [31:0] mac_count,
    output logic [31:0] output_count
);
    typedef enum logic [2:0] {G_IDLE, G_CLEAR, G_MAC, G_FINAL, G_DRAIN} gstate_t;
    gstate_t gs;

    logic [ADDR_WIDTH-1:0] base_a_r, base_b_r;
    logic [15:0] stride_a_r, stride_b_r, rows_r, cols_r, k_size_r;
    logic [15:0] i, j, k, p_i, p_j;
    logic        have_prev;

    // ---- address generation (same formula as the original controller) ----
    logic [31:0] calc_a, calc_b;
    always_comb begin
        calc_a = base_a_r + (i * stride_a_r) + k;
        calc_b = base_b_r + (k * stride_b_r) + j;
    end

    // ---- token generated this cycle ----
    logic        t_mac, t_clear, t_cap;
    logic [15:0] t_row, t_col;
    always_comb begin
        t_mac = 1'b0; t_clear = 1'b0; t_cap = 1'b0; t_row = p_i; t_col = p_j;
        spad_a_en = 1'b0; spad_b_en = 1'b0;
        spad_a_addr = calc_a[ADDR_WIDTH-1:0];
        spad_b_addr = calc_b[ADDR_WIDTH-1:0];
        case (gs)
            G_CLEAR: begin t_clear = 1'b1; t_cap = have_prev; end
            G_MAC:   begin t_mac = 1'b1; spad_a_en = 1'b1; spad_b_en = 1'b1; end
            G_FINAL: begin t_clear = 1'b1; t_cap = 1'b1; end
            default: ;
        endcase
    end

    // ---- 2-stage token pipeline, aligned with scratchpad read latency ----
    logic        m1, c1, cap1, m2, c2, cap2;
    logic [15:0] r1, q1, r2, q2;
    always_ff @(posedge clk) begin
        if (rst) begin
            m1 <= 0; c1 <= 0; cap1 <= 0; m2 <= 0; c2 <= 0; cap2 <= 0;
            r1 <= 0; q1 <= 0; r2 <= 0; q2 <= 0;
        end else begin
            m1 <= t_mac; c1 <= t_clear; cap1 <= t_cap; r1 <= t_row; q1 <= t_col;
            m2 <= m1;    c2 <= c1;      cap2 <= cap1;  r2 <= r1;    q2 <= q1;
        end
    end

    // ---- MAC unit (unchanged module) ----
    logic signed [ACC_WIDTH-1:0] mac_accumulator;
    mac_unit #(.OPERAND_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) mac_inst (
        .clk(clk), .rst(rst),
        .enable(m2), .clear_acc(c2),
        .operand_a($signed(spad_a_rdata)), .operand_b($signed(spad_b_rdata)),
        .accumulator(mac_accumulator)
    );

    // ---- result capture: accumulator is final in the CLEAR cycle after the last MAC ----
    always_ff @(posedge clk) begin
        if (rst) begin
            result_valid <= 0; result_row <= 0; result_col <= 0; result_data <= 0;
        end else begin
            result_valid <= 1'b0;
            if (c2 && cap2) begin
                result_valid <= 1'b1;
                result_row   <= r2;
                result_col   <= q2;
                result_data  <= mac_accumulator;
            end
        end
    end

    // ---- generator FSM ----
    logic [3:0] fin_sh;   // fin_sh[3] = done, 4 cycles after the FINAL token
    always_ff @(posedge clk) begin
        if (rst) begin
            gs <= G_IDLE; i <= 0; j <= 0; k <= 0; p_i <= 0; p_j <= 0; have_prev <= 0;
            base_a_r <= 0; base_b_r <= 0; stride_a_r <= 0; stride_b_r <= 0;
            rows_r <= 0; cols_r <= 0; k_size_r <= 0; fin_sh <= 0;
        end else begin
            fin_sh <= {fin_sh[2:0], (gs == G_FINAL)};
            case (gs)
                G_IDLE: if (start) begin
                    base_a_r <= base_addr_a; base_b_r <= base_addr_b;
                    stride_a_r <= stride_a;  stride_b_r <= stride_b;
                    rows_r <= rows; cols_r <= cols; k_size_r <= k_size;
                    i <= 0; j <= 0; k <= 0; have_prev <= 0;
                    gs <= G_CLEAR;
                end
                G_CLEAR: begin k <= 0; gs <= G_MAC; end
                G_MAC: begin
                    if (k == k_size_r - 1) begin
                        p_i <= i; p_j <= j; have_prev <= 1'b1;
                        if ((i == rows_r - 1) && (j == cols_r - 1)) gs <= G_FINAL;
                        else begin
                            if (j < cols_r - 1) j <= j + 1'b1;
                            else begin j <= 0; i <= i + 1'b1; end
                            gs <= G_CLEAR;
                        end
                    end else k <= k + 1'b1;
                end
                G_FINAL: gs <= G_DRAIN;
                G_DRAIN: if (fin_sh[3]) gs <= G_IDLE;
                default: gs <= G_IDLE;
            endcase
        end
    end

    assign done = fin_sh[3];
    assign busy = (gs != G_IDLE) && !fin_sh[3];

    // ---- counters (same outputs as the original) ----
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0; a_read_count <= 0; b_read_count <= 0; mac_count <= 0; output_count <= 0;
        end else begin
            if (gs != G_IDLE) cycle_count <= cycle_count + 1;
            if (spad_a_en) a_read_count <= a_read_count + 1;
            if (spad_b_en) b_read_count <= b_read_count + 1;
            if (m2)        mac_count    <= mac_count + 1;
            if (c2 && cap2) output_count <= output_count + 1;
        end
    end
endmodule
`default_nettype wire