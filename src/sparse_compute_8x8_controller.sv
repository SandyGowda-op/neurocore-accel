//==============================================================================
//
// Module      : sparse_compute_8x8_controller
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   Complete 8x8 sparse matrix multiplication controller using 2:4
//   structured sparsity.
//
//   Computes:
//
//       C[8x8] = A[8x8] x B[8x8]
//
//   A is supplied in compressed 2:4 format:
//
//       Each A row:
//           group 0 -> 2 compressed values + 3-bit metadata
//           group 1 -> 2 compressed values + 3-bit metadata
//
//       8 rows x 4 compressed values = 32 A values
//       8 rows x 2 metadata groups  = 16 metadata values
//
//   B is supplied as a dense 8x8 matrix.
//
//   A single MAC unit is reused sequentially.
//
//   Dense MAC operations:
//       8 x 8 x 8 = 512
//
//   Sparse MAC operations:
//       8 x 8 x 4 = 256
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module sparse_compute_8x8_controller #(

    parameter int DATA_WIDTH = 32,
    parameter int ACC_WIDTH  = 64

)(

    //--------------------------------------------------------------------------
    // Global
    //--------------------------------------------------------------------------

    input logic clk,
    input logic rst,

    //--------------------------------------------------------------------------
    // Control
    //--------------------------------------------------------------------------

    input  logic start,
    output logic busy,
    output logic done,

    //--------------------------------------------------------------------------
    // Compressed A
    //
    // sparse_a[row][0] -> first non-zero of group 0
    // sparse_a[row][1] -> second non-zero of group 0
    // sparse_a[row][2] -> first non-zero of group 1
    // sparse_a[row][3] -> second non-zero of group 1
    //--------------------------------------------------------------------------

    input logic signed [DATA_WIDTH-1:0] sparse_a [0:7][0:3],

    //--------------------------------------------------------------------------
    // Dense B
    //
    // b[k][column]
    //--------------------------------------------------------------------------

    input logic signed [DATA_WIDTH-1:0] b [0:7][0:7],

    //--------------------------------------------------------------------------
    // Metadata
    //
    // metadata[row][0] -> A[row][0:3]
    // metadata[row][1] -> A[row][4:7]
    //--------------------------------------------------------------------------

    input logic [2:0] metadata [0:7][0:1],

    //--------------------------------------------------------------------------
    // Result
    //--------------------------------------------------------------------------

    output logic signed [ACC_WIDTH-1:0] result [0:7][0:7],

    //--------------------------------------------------------------------------
    // Verification Metric
    //
    // Total number of executed sparse MAC operations.
    //--------------------------------------------------------------------------

    output logic [15:0] mac_count

);

    //==========================================================================
    // Parameter Checks
    //==========================================================================

    initial begin

        if (DATA_WIDTH <= 0)
            $fatal(
                "sparse_compute_8x8_controller: DATA_WIDTH must be > 0"
            );

        if (ACC_WIDTH <= 0)
            $fatal(
                "sparse_compute_8x8_controller: ACC_WIDTH must be > 0"
            );

    end

    //==========================================================================
    // State Machine
    //==========================================================================

    // OPTIMIZED: 1 clear slot + 4 back-to-back MACs per output element (5 cycles/output).
    // The previous output's accumulator is stored in the same cycle the next clear is applied
    // (accumulator is final in the cycle after the last MAC; clear takes effect at the edge).
    typedef enum logic [2:0] {
        IDLE,
        CLR,
        MAC,
        FINAL,
        COMPLETE
    } state_t;

    state_t state;

    logic [2:0] current_row;
    logic [2:0] current_col;
    logic [2:0] prev_row;
    logic [2:0] prev_col;
    logic [1:0] m;            // 0..3: which of the 4 kept products of this output
    logic       have_prev;

    logic [3:0] metadata_enable_mask;
    logic [1:0] metadata_index0;
    logic [1:0] metadata_index1;

    // m[1] selects the 4-wide group (0 or 1); m[0] selects first/second kept element of the group
    metadata_decoder u_metadata_decoder (
        .metadata    (metadata[current_row][m[1]]),
        .enable_mask (metadata_enable_mask),
        .index0      (metadata_index0),
        .index1      (metadata_index1)
    );

    logic [2:0] logical_k;
    always_comb logical_k = {m[1], (m[0] ? metadata_index1 : metadata_index0)};

    logic signed [DATA_WIDTH-1:0] mac_operand_a;
    logic signed [DATA_WIDTH-1:0] mac_operand_b;
    always_comb begin
        mac_operand_a = '0;
        mac_operand_b = '0;
        if (state == MAC) begin
            mac_operand_a = sparse_a[current_row][m];
            mac_operand_b = b[logical_k][current_col];
        end
    end

    logic mac_enable;
    logic clear_acc;
    logic signed [ACC_WIDTH-1:0] mac_accumulator;

    mac_unit #(
        .OPERAND_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_mac (
        .clk(clk),
        .rst(rst),
        .enable(mac_enable),
        .clear_acc(clear_acc),
        .operand_a(mac_operand_a),
        .operand_b(mac_operand_b),
        .accumulator(mac_accumulator)
    );

    always_comb begin
        mac_enable = (state == MAC);
        clear_acc  = (state == CLR);
    end

    integer row_index;
    integer col_index;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            current_row <= 3'd0; current_col <= 3'd0;
            prev_row <= 3'd0;    prev_col <= 3'd0;
            m <= 2'd0; have_prev <= 1'b0;
            busy <= 1'b0; done <= 1'b0;
            mac_count <= 16'd0;
            for (row_index = 0; row_index < 8; row_index = row_index + 1)
                for (col_index = 0; col_index < 8; col_index = col_index + 1)
                    result[row_index][col_index] <= '0;
        end
        else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        current_row <= 3'd0; current_col <= 3'd0;
                        m <= 2'd0; have_prev <= 1'b0;
                        mac_count <= 16'd0;
                        state <= CLR;
                    end
                end
                CLR: begin
                    if (have_prev)
                        result[prev_row][prev_col] <= mac_accumulator;
                    m <= 2'd0;
                    state <= MAC;
                end
                MAC: begin
                    mac_count <= mac_count + 16'd1;
                    if (m == 2'd3) begin
                        prev_row <= current_row; prev_col <= current_col; have_prev <= 1'b1;
                        m <= 2'd0;
                        if ((current_row == 3'd7) && (current_col == 3'd7)) begin
                            state <= FINAL;
                        end
                        else begin
                            if (current_col < 3'd7) current_col <= current_col + 3'd1;
                            else begin current_col <= 3'd0; current_row <= current_row + 3'd1; end
                            state <= CLR;
                        end
                    end
                    else m <= m + 2'd1;
                end
                FINAL: begin
                    result[prev_row][prev_col] <= mac_accumulator;
                    state <= COMPLETE;
                end
                COMPLETE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
                default: begin
                    state <= IDLE; busy <= 1'b0; done <= 1'b0;
                end
            endcase
        end
    end
endmodule
`default_nettype wire