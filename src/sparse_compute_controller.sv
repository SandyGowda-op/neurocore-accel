//==============================================================================
// Module      : sparse_compute_controller
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   Sparse compute datapath for NVIDIA-style 2:4 structured sparsity.
//
//   For every group of four logical A elements:
//       - Metadata identifies two non-zero positions.
//       - Only those two A values participate in MAC operations.
//       - B is accessed using the decoded logical positions.
//
//   This module is intentionally separate from the verified dense
//   compute_controller so that sparse development cannot disturb the
//   existing dense datapath.
//
// Current implementation:
//   - One output element at a time
//   - 8-element K dimension
//   - 2:4 sparsity
//   - Two MAC operations per 4-element group
//   - Four MAC operations for an 8-element K dimension
//   - Uses existing metadata_decoder
//   - Uses existing mac_unit
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module sparse_compute_controller #(
    parameter int DATA_WIDTH = 32,
    parameter int ACC_WIDTH  = 64,
    parameter int K_SIZE     = 8
)(
    //--------------------------------------------------------------------------
    // Global
    //--------------------------------------------------------------------------

    input  logic clk,
    input  logic rst,

    //--------------------------------------------------------------------------
    // Control
    //--------------------------------------------------------------------------

    input  logic start,
    output logic busy,
    output logic done,

    //--------------------------------------------------------------------------
    // Sparse A Values
    //
    // Four logical values are represented by two stored non-zero values.
    //
    // For an 8-element K dimension:
    //
    //   Group 0 -> A[0..3] -> 2 values
    //   Group 1 -> A[4..7] -> 2 values
    //
    // The controller expects the compressed values in logical group order.
    //--------------------------------------------------------------------------

    input logic signed [DATA_WIDTH-1:0] sparse_a_value0,
    input logic signed [DATA_WIDTH-1:0] sparse_a_value1,
    input logic signed [DATA_WIDTH-1:0] sparse_a_value2,
    input logic signed [DATA_WIDTH-1:0] sparse_a_value3,

    //--------------------------------------------------------------------------
    // Dense B Values
    //
    // B contains the complete K dimension.
    //--------------------------------------------------------------------------

    input logic signed [DATA_WIDTH-1:0] b_value0,
    input logic signed [DATA_WIDTH-1:0] b_value1,
    input logic signed [DATA_WIDTH-1:0] b_value2,
    input logic signed [DATA_WIDTH-1:0] b_value3,
    input logic signed [DATA_WIDTH-1:0] b_value4,
    input logic signed [DATA_WIDTH-1:0] b_value5,
    input logic signed [DATA_WIDTH-1:0] b_value6,
    input logic signed [DATA_WIDTH-1:0] b_value7,

    //--------------------------------------------------------------------------
    // 2:4 Metadata
    //
    // metadata0 describes A[0:3]
    // metadata1 describes A[4:7]
    //--------------------------------------------------------------------------

    input logic [2:0] metadata0,
    input logic [2:0] metadata1,

    //--------------------------------------------------------------------------
    // Result
    //--------------------------------------------------------------------------

    output logic signed [ACC_WIDTH-1:0] result,

    //--------------------------------------------------------------------------
    // Research / Verification Metrics
    //--------------------------------------------------------------------------

    output logic [15:0] mac_count
);

    //==========================================================================
    // Parameters
    //==========================================================================

    initial begin
        if (DATA_WIDTH <= 0)
            $fatal("sparse_compute_controller: DATA_WIDTH must be > 0");

        if (ACC_WIDTH <= 0)
            $fatal("sparse_compute_controller: ACC_WIDTH must be > 0");

        if (K_SIZE != 8)
            $fatal("sparse_compute_controller: current implementation requires K_SIZE=8");
    end

    //==========================================================================
    // Metadata Decoder Signals
    //==========================================================================

    logic [3:0] enable_mask0;
    logic [3:0] enable_mask1;

    logic [1:0] index0_0;
    logic [1:0] index1_0;

    logic [1:0] index0_1;
    logic [1:0] index1_1;

    metadata_decoder decoder0 (
        .metadata    (metadata0),
        .enable_mask (enable_mask0),
        .index0      (index0_0),
        .index1      (index1_0)
    );

    metadata_decoder decoder1 (
        .metadata    (metadata1),
        .enable_mask (enable_mask1),
        .index0      (index0_1),
        .index1      (index1_1)
    );

    //==========================================================================
    // B Selection
    //
    // Convert the logical index generated by metadata_decoder into the
    // corresponding dense B value.
    //==========================================================================

    logic signed [DATA_WIDTH-1:0] b_selected0;
    logic signed [DATA_WIDTH-1:0] b_selected1;

    always_comb begin

        b_selected0 = '0;
        b_selected1 = '0;

        // Group 0 : logical B positions 0..3

        case (index0_0)
            2'd0: b_selected0 = b_value0;
            2'd1: b_selected0 = b_value1;
            2'd2: b_selected0 = b_value2;
            2'd3: b_selected0 = b_value3;
            default: b_selected0 = '0;
        endcase

        // Group 1 : logical B positions 4..7

        case (index0_1)
            2'd0: b_selected1 = b_value4;
            2'd1: b_selected1 = b_value5;
            2'd2: b_selected1 = b_value6;
            2'd3: b_selected1 = b_value7;
            default: b_selected1 = '0;
        endcase

    end

    //==========================================================================
    // Sparse A Operand Selection
    //
    // The four compressed A values are stored in this order:
    //
    //   sparse_a_value0 -> group 0, first non-zero
    //   sparse_a_value1 -> group 0, second non-zero
    //   sparse_a_value2 -> group 1, first non-zero
    //   sparse_a_value3 -> group 1, second non-zero
    //
    //==========================================================================

    logic signed [DATA_WIDTH-1:0] a_selected0;
    logic signed [DATA_WIDTH-1:0] a_selected1;

    always_comb begin

        a_selected0 = '0;
        a_selected1 = '0;

        if (mac_count < 16'd2) begin
            if (mac_count == 16'd0)
                a_selected0 = sparse_a_value0;
            else
                a_selected0 = sparse_a_value1;
        end
        else begin
            if (mac_count == 16'd2)
                a_selected0 = sparse_a_value2;
            else
                a_selected0 = sparse_a_value3;
        end

        // Second operand is selected separately during the sequential
        // execution below.
        a_selected1 = '0;

    end

    //==========================================================================
    // MAC Unit
    //==========================================================================

    logic mac_enable;
    logic mac_clear;

    logic signed [DATA_WIDTH-1:0] mac_operand_a;
    logic signed [DATA_WIDTH-1:0] mac_operand_b;

    logic signed [ACC_WIDTH-1:0] mac_accumulator;

    mac_unit #(
        .OPERAND_WIDTH (DATA_WIDTH),
        .ACC_WIDTH     (ACC_WIDTH)
    ) mac (
        .clk        (clk),
        .rst        (rst),
        .enable     (mac_enable),
        .clear_acc  (mac_clear),
        .operand_a  (mac_operand_a),
        .operand_b  (mac_operand_b),
        .accumulator(mac_accumulator)
    );

    //==========================================================================
    // Internal Control
    //==========================================================================

    typedef enum logic [2:0]
    {
        IDLE,
        MAC_0,
        MAC_1,
        MAC_2,
        MAC_3,
        COMPLETE
    } sparse_state_t;

    sparse_state_t state;

    //==========================================================================
    // Current MAC Operand Selection
    //==========================================================================

    always_comb begin

        mac_operand_a = '0;
        mac_operand_b = '0;

        case (state)

            //--------------------------------------------------------------
            // Group 0, first non-zero
            //--------------------------------------------------------------

            MAC_0:
            begin
                mac_operand_a = sparse_a_value0;

                case (index0_0)
                    2'd0: mac_operand_b = b_value0;
                    2'd1: mac_operand_b = b_value1;
                    2'd2: mac_operand_b = b_value2;
                    2'd3: mac_operand_b = b_value3;
                    default: mac_operand_b = '0;
                endcase
            end

            //--------------------------------------------------------------
            // Group 0, second non-zero
            //--------------------------------------------------------------

            MAC_1:
            begin
                mac_operand_a = sparse_a_value1;

                case (index1_0)
                    2'd0: mac_operand_b = b_value0;
                    2'd1: mac_operand_b = b_value1;
                    2'd2: mac_operand_b = b_value2;
                    2'd3: mac_operand_b = b_value3;
                    default: mac_operand_b = '0;
                endcase
            end

            //--------------------------------------------------------------
            // Group 1, first non-zero
            //--------------------------------------------------------------

            MAC_2:
            begin
                mac_operand_a = sparse_a_value2;

                case (index0_1)
                    2'd0: mac_operand_b = b_value4;
                    2'd1: mac_operand_b = b_value5;
                    2'd2: mac_operand_b = b_value6;
                    2'd3: mac_operand_b = b_value7;
                    default: mac_operand_b = '0;
                endcase
            end

            //--------------------------------------------------------------
            // Group 1, second non-zero
            //--------------------------------------------------------------

            MAC_3:
            begin
                mac_operand_a = sparse_a_value3;

                case (index1_1)
                    2'd0: mac_operand_b = b_value4;
                    2'd1: mac_operand_b = b_value5;
                    2'd2: mac_operand_b = b_value6;
                    2'd3: mac_operand_b = b_value7;
                    default: mac_operand_b = '0;
                endcase
            end

            default:
            begin
                mac_operand_a = '0;
                mac_operand_b = '0;
            end

        endcase

    end

    //==========================================================================
    // MAC Control
    //==========================================================================

    always_comb begin

        mac_enable = 1'b0;
        mac_clear  = 1'b0;

        case (state)

            MAC_0,
            MAC_1,
            MAC_2,
            MAC_3:
                mac_enable = 1'b1;

            default:
                mac_enable = 1'b0;

        endcase

        // Clear the accumulator when a new operation begins.
        if (start && state == IDLE)
            mac_clear = 1'b1;

    end

    //==========================================================================
    // Controller FSM
    //==========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            state    <= IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            result   <= '0;
            mac_count <= 16'd0;

        end
        else begin

            done <= 1'b0;

            case (state)

                //------------------------------------------------------------------
                // Waiting for start
                //------------------------------------------------------------------

                IDLE:
                begin

                    busy      <= 1'b0;
                    mac_count <= 16'd0;

                    if (start) begin

                        busy      <= 1'b1;
                        mac_count <= 16'd0;
                        state     <= MAC_0;

                    end

                end

                //------------------------------------------------------------------
                // MAC operation 0
                //------------------------------------------------------------------

                MAC_0:
                begin

                    mac_count <= mac_count + 16'd1;
                    state     <= MAC_1;
                end

                //------------------------------------------------------------------
                // MAC operation 1
                //------------------------------------------------------------------

                MAC_1:
                begin

                    mac_count <= mac_count + 16'd1;
                    state     <= MAC_2;
                end

                //------------------------------------------------------------------
                // MAC operation 2
                //------------------------------------------------------------------

                MAC_2:
                begin

                    mac_count <= mac_count + 16'd1;
                    state     <= MAC_3;
                end

                //------------------------------------------------------------------
                // MAC operation 3
                //------------------------------------------------------------------

                MAC_3:
                begin

                    mac_count <= mac_count + 16'd1;
                    state     <= COMPLETE;
                end

                //------------------------------------------------------------------
                // Complete
                //------------------------------------------------------------------

                COMPLETE:
                begin

                    result <= mac_accumulator;
                    busy   <= 1'b0;
                    done   <= 1'b1;

                    state <= IDLE;

                end

                //------------------------------------------------------------------
                // Safety
                //------------------------------------------------------------------

                default:
                begin

                    state <= IDLE;
                    busy  <= 1'b0;
                    done  <= 1'b0;

                end

            endcase

        end

    end

endmodule

`default_nettype wire