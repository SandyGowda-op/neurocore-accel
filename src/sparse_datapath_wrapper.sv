//==============================================================================
//
// Module      : sparse_datapath_wrapper
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   Integration wrapper for the sparse datapath.
//
//   Dataflow:
//
//       Sparse Tile Request
//              |
//              v
//       Transfer Engine
//              |
//              v
//       Scratchpad Controller
//              |
//              v
//       Scratchpad
//        A / B / Metadata
//              |
//              v
//       Sparse operand readout
//              |
//              v
//       Sparse Compute Controller
//              |
//              v
//            Result
//
// Current integration scope:
//   - 2:4 structured sparsity
//   - Compressed A values
//   - Dense B values
//   - Sparse metadata
//   - Existing verified dense path is not modified
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

import tile_pkg::*;

module sparse_datapath_wrapper #(

    parameter integer BURST_BYTES      = 128,
    parameter integer DATA_WIDTH       = 64,
    parameter integer SPAD_DATA_WIDTH  = 32,
    parameter integer SPAD_ADDR_WIDTH  = 6

)(

    //--------------------------------------------------------------------------

    // Global

    //--------------------------------------------------------------------------

    input logic clk,
    input logic rst,

    //--------------------------------------------------------------------------

    // Sparse Scheduler Interface

    //--------------------------------------------------------------------------

    input  sparse_tile_request_t sparse_tile_request,
    input  logic                 sparse_tile_request_valid,
    output logic                 sparse_tile_request_ready,

    //--------------------------------------------------------------------------

    // Main Memory Interface

    //--------------------------------------------------------------------------

    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    output logic [31:0] mem_req_bytes,

    input  logic        mem_rvalid,
    input  logic [63:0] mem_rdata,
    input  logic        mem_rlast,

    //--------------------------------------------------------------------------

    // Sparse Compute Control

    //--------------------------------------------------------------------------

    input  logic compute_start,
    output logic compute_busy,
    output logic compute_done,
    output logic signed [63:0] compute_result,
    output logic [31:0]        compute_mac_count,

    //--------------------------------------------------------------------------

    // Status

    //--------------------------------------------------------------------------

    output logic transfer_busy,
    output logic transfer_done,
    output logic datapath_busy,
    output logic datapath_done

);

    //==========================================================================
    // Parameter Checks
    //==========================================================================

    initial begin

        if (DATA_WIDTH != 64)
            $fatal(
                "sparse_datapath_wrapper: DATA_WIDTH must currently be 64"
            );

        if (SPAD_DATA_WIDTH != 32)
            $fatal(
                "sparse_datapath_wrapper: SPAD_DATA_WIDTH must currently be 32"
            );

        if (SPAD_ADDR_WIDTH != 6)
            $fatal(
                "sparse_datapath_wrapper: SPAD_ADDR_WIDTH must currently be 6"
            );

    end

    //==========================================================================
    // Transfer Engine -> Scratchpad Controller
    //==========================================================================

    logic        te_spad_write_enable;
    logic [3:0]  te_spad_bank;
    logic [31:0] te_spad_address;
    logic [63:0] te_spad_write_data;
    logic        te_spad_ready;

    //==========================================================================
    // Transfer Completion Latch
    //==========================================================================

    logic transfer_complete_latched;

    //==========================================================================
    // Transfer Engine
    //==========================================================================

    transfer_engine #(

        .BURST_BYTES(BURST_BYTES),
        .DATA_WIDTH (DATA_WIDTH)

    ) u_transfer_engine (

        .clk(clk),
        .rst(rst),

        //----------------------------------------------------------------------
        // Dense interface disabled
        //----------------------------------------------------------------------

        .tile_request('0),
        .tile_request_valid(1'b0),
        .tile_request_ready(),

        //----------------------------------------------------------------------
        // Sparse scheduler
        //----------------------------------------------------------------------

        .sparse_tile_request(
            sparse_tile_request
        ),

        .sparse_tile_request_valid(
            sparse_tile_request_valid
        ),

        .sparse_tile_request_ready(
            sparse_tile_request_ready
        ),

        //----------------------------------------------------------------------
        // Main memory
        //----------------------------------------------------------------------

        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr),
        .mem_req_bytes(mem_req_bytes),

        .mem_rvalid(mem_rvalid),
        .mem_rdata(mem_rdata),
        .mem_rlast(mem_rlast),

        //----------------------------------------------------------------------
        // Scratchpad DMA
        //----------------------------------------------------------------------

        .spad_write_enable(
            te_spad_write_enable
        ),

        .spad_bank(
            te_spad_bank
        ),

        .spad_address(
            te_spad_address
        ),

        .spad_write_data(
            te_spad_write_data
        ),

        .spad_ready(
            te_spad_ready
        ),

        //----------------------------------------------------------------------
        // Status
        //----------------------------------------------------------------------

        .transfer_busy(
            transfer_busy
        ),

        .transfer_done(
            transfer_done
        )

    );

    //==========================================================================
    // Transfer Completion Latch
    //==========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            transfer_complete_latched <= 1'b0;

        end

        else begin

            if (transfer_done) begin

                transfer_complete_latched <= 1'b1;

            end

            if (compute_start &&
                transfer_complete_latched) begin

                transfer_complete_latched <= 1'b0;

            end

        end

    end

    //==========================================================================
    // Scratchpad Controller
    //==========================================================================

    logic [1:0] scratchpad_dma_bank_sel;
    logic       scratchpad_dma_en;
    logic       scratchpad_dma_we;

    logic [SPAD_ADDR_WIDTH-1:0] scratchpad_dma_addr;
    logic [SPAD_DATA_WIDTH-1:0] scratchpad_dma_wdata;
    logic [SPAD_DATA_WIDTH-1:0] scratchpad_dma_rdata;

    scratchpad_controller #(

        .DMA_DATA_WIDTH  (64),
        .SPAD_DATA_WIDTH (SPAD_DATA_WIDTH),
        .SPAD_ADDR_WIDTH (SPAD_ADDR_WIDTH)

    ) u_scratchpad_controller (

        .clk(clk),
        .rst(rst),

        //----------------------------------------------------------------------
        // Transfer Engine
        //----------------------------------------------------------------------

        .dma_write_enable(
            te_spad_write_enable
        ),

        .dma_bank(
            te_spad_bank
        ),

        .dma_address(
            te_spad_address
        ),

        .dma_write_data(
            te_spad_write_data
        ),

        .dma_ready(
            te_spad_ready
        ),

        //----------------------------------------------------------------------
        // Scratchpad DMA
        //----------------------------------------------------------------------

        .spad_bank_sel(
            scratchpad_dma_bank_sel
        ),

        .spad_en(
            scratchpad_dma_en
        ),

        .spad_we(
            scratchpad_dma_we
        ),

        .spad_addr(
            scratchpad_dma_addr
        ),

        .spad_wdata(
            scratchpad_dma_wdata
        )

    );

    //==========================================================================
    // Sparse Scratchpad Compute Interface
    //
    // Bank mapping:
    //
    //   Bank A -> compressed A values
    //   Bank B -> dense B values
    //   Bank C -> metadata
    //
    //==========================================================================

    logic sparse_a_en;
    logic sparse_a_we;
    logic [SPAD_ADDR_WIDTH-1:0] sparse_a_addr;
    logic [SPAD_DATA_WIDTH-1:0] sparse_a_wdata;
    logic [SPAD_DATA_WIDTH-1:0] sparse_a_rdata;

    logic sparse_b_en;
    logic sparse_b_we;
    logic [SPAD_ADDR_WIDTH-1:0] sparse_b_addr;
    logic [SPAD_DATA_WIDTH-1:0] sparse_b_wdata;
    logic [SPAD_DATA_WIDTH-1:0] sparse_b_rdata;

    logic sparse_metadata_en;
    logic sparse_metadata_we;
    logic [SPAD_ADDR_WIDTH-1:0] sparse_metadata_addr;
    logic [SPAD_DATA_WIDTH-1:0] sparse_metadata_wdata;
    logic [SPAD_DATA_WIDTH-1:0] sparse_metadata_rdata;

    //--------------------------------------------------------------------------
    // Sparse compute path is read-only.
    //--------------------------------------------------------------------------

    always_comb begin

        sparse_a_we    = 1'b0;
        sparse_a_wdata = '0;

        sparse_b_we    = 1'b0;
        sparse_b_wdata = '0;

        sparse_metadata_we    = 1'b0;
        sparse_metadata_wdata = '0;

    end

    //==========================================================================
    // Scratchpad
    //==========================================================================

    logic [SPAD_DATA_WIDTH-1:0] unused_compute_rdata;

    scratchpad #(

        .DATA_WIDTH (SPAD_DATA_WIDTH),
        .MATRIX_DIM (8),
        .DEPTH      (64),
        .ADDR_WIDTH (SPAD_ADDR_WIDTH)

    ) u_scratchpad (

        .clk(clk),
        .rst(rst),

        //----------------------------------------------------------------------
        // DMA interface
        //----------------------------------------------------------------------

        .dma_bank_sel(
            scratchpad_dma_bank_sel
        ),

        .dma_en(
            scratchpad_dma_en
        ),

        .dma_we(
            scratchpad_dma_we
        ),

        .dma_addr(
            scratchpad_dma_addr
        ),

        .dma_wdata(
            scratchpad_dma_wdata
        ),

        .dma_rdata(
            scratchpad_dma_rdata
        ),

        //----------------------------------------------------------------------
        // Existing dense compute interface disabled
        //----------------------------------------------------------------------

        .compute_bank_sel(2'b00),
        .compute_en(1'b0),
        .compute_we(1'b0),
        .compute_addr('0),
        .compute_wdata('0),
        .compute_rdata(unused_compute_rdata),

        //----------------------------------------------------------------------
        // Sparse A
        //----------------------------------------------------------------------

        .sparse_a_en(
            sparse_a_en
        ),

        .sparse_a_we(
            sparse_a_we
        ),

        .sparse_a_addr(
            sparse_a_addr
        ),

        .sparse_a_wdata(
            sparse_a_wdata
        ),

        .sparse_a_rdata(
            sparse_a_rdata
        ),

        //----------------------------------------------------------------------
        // Sparse B
        //----------------------------------------------------------------------

        .sparse_b_en(
            sparse_b_en
        ),

        .sparse_b_we(
            sparse_b_we
        ),

        .sparse_b_addr(
            sparse_b_addr
        ),

        .sparse_b_wdata(
            sparse_b_wdata
        ),

        .sparse_b_rdata(
            sparse_b_rdata
        ),

        //----------------------------------------------------------------------
        // Sparse metadata
        //----------------------------------------------------------------------

        .sparse_metadata_en(
            sparse_metadata_en
        ),

        .sparse_metadata_we(
            sparse_metadata_we
        ),

        .sparse_metadata_addr(
            sparse_metadata_addr
        ),

        .sparse_metadata_wdata(
            sparse_metadata_wdata
        ),

        .sparse_metadata_rdata(
            sparse_metadata_rdata
        )

    );

    //==========================================================================
    // Captured Sparse Operands
    //==========================================================================

    logic signed [31:0] captured_a0;
    logic signed [31:0] captured_a1;
    logic signed [31:0] captured_a2;
    logic signed [31:0] captured_a3;

    logic signed [31:0] captured_b0;
    logic signed [31:0] captured_b1;
    logic signed [31:0] captured_b2;
    logic signed [31:0] captured_b3;
    logic signed [31:0] captured_b4;
    logic signed [31:0] captured_b5;
    logic signed [31:0] captured_b6;
    logic signed [31:0] captured_b7;

    logic [2:0] captured_metadata0;
    logic [2:0] captured_metadata1;

    //==========================================================================
    // Sparse Read FSM
    //==========================================================================

    typedef enum logic [3:0]
    {
        READ_IDLE,

        READ_A_REQUEST,
        READ_A_WAIT1,
        READ_A_WAIT2,

        READ_B_REQUEST,
        READ_B_WAIT1,
        READ_B_WAIT2,

        READ_META_REQUEST,
        READ_META_WAIT1,
        READ_META_WAIT2,

        READ_COMPLETE,
        COMPUTE_WAIT

    } read_state_t;

    read_state_t read_state;

    logic [3:0] read_index;

    //==========================================================================
    // Latched Compute Request
    //==========================================================================

    logic compute_request_pending;

    //==========================================================================
    // Sparse Compute Start Pulse
    //==========================================================================

    logic sparse_compute_start;

    //==========================================================================
    // Sparse Read Address Generation
    //==========================================================================

    always_comb begin

        sparse_a_en          = 1'b0;
        sparse_a_addr        = '0;

        sparse_b_en          = 1'b0;
        sparse_b_addr        = '0;

        sparse_metadata_en   = 1'b0;
        sparse_metadata_addr = '0;

        case (read_state)

            //------------------------------------------------------------------
            // A
            //------------------------------------------------------------------

            READ_A_REQUEST: begin

                sparse_a_en   = 1'b1;
                sparse_a_addr = read_index;

            end

            //------------------------------------------------------------------
            // B
            //------------------------------------------------------------------

            READ_B_REQUEST: begin

                sparse_b_en   = 1'b1;
                sparse_b_addr = read_index;

            end

            //------------------------------------------------------------------
            // Metadata
            //
            // IMPORTANT:
            //
            // scratchpad_controller converts each 64-bit DMA beat into
            // two 32-bit words:
            //
            //   lower 32 bits -> address N
            //   upper 32 bits -> address N+1
            //
            // Therefore two metadata beats occupy:
            //
            //   beat 0 -> addresses 0,1
            //   beat 1 -> addresses 2,3
            //
            // The metadata values themselves are therefore at:
            //
            //   META0 -> address 0
            //   META1 -> address 2
            //
            //------------------------------------------------------------------

            READ_META_REQUEST: begin

                sparse_metadata_en = 1'b1;

                if (read_index == 4'd0)

                    sparse_metadata_addr = 6'd0;

                else

                    sparse_metadata_addr = 6'd2;

            end

            default: begin

            end

        endcase

    end

    //==========================================================================
    // Sparse Read Controller
    //==========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            read_state <= READ_IDLE;
            read_index <= 4'd0;

            compute_request_pending <= 1'b0;
            sparse_compute_start    <= 1'b0;

            captured_a0 <= '0;
            captured_a1 <= '0;
            captured_a2 <= '0;
            captured_a3 <= '0;

            captured_b0 <= '0;
            captured_b1 <= '0;
            captured_b2 <= '0;
            captured_b3 <= '0;
            captured_b4 <= '0;
            captured_b5 <= '0;
            captured_b6 <= '0;
            captured_b7 <= '0;

            captured_metadata0 <= '0;
            captured_metadata1 <= '0;

        end

        else begin

            //------------------------------------------------------------------
            // sparse_compute_start is a one-cycle pulse.
            //------------------------------------------------------------------

            sparse_compute_start <= 1'b0;

            case (read_state)

                //==============================================================
                // IDLE
                //==============================================================

                READ_IDLE: begin

                    if (compute_start &&
                        transfer_complete_latched) begin

                        compute_request_pending <= 1'b1;
                        read_index <= 4'd0;

                        read_state <= READ_A_REQUEST;

                    end

                end

                //==============================================================
                // A REQUEST
                //==============================================================

                READ_A_REQUEST: begin

                    read_state <= READ_A_WAIT1;

                end

                //==============================================================
                // A WAIT 1
                //==============================================================

                READ_A_WAIT1: begin

                    read_state <= READ_A_WAIT2;

                end

                //==============================================================
                // A WAIT 2 + CAPTURE
                //==============================================================

                READ_A_WAIT2: begin

                    case (read_index)

                        4'd0:
                            captured_a0 <= sparse_a_rdata;

                        4'd1:
                            captured_a1 <= sparse_a_rdata;

                        4'd2:
                            captured_a2 <= sparse_a_rdata;

                        4'd3:
                            captured_a3 <= sparse_a_rdata;

                        default:
                            ;

                    endcase

                    if (read_index == 4'd3) begin

                        read_index <= 4'd0;
                        read_state <= READ_B_REQUEST;

                    end

                    else begin

                        read_index <= read_index + 4'd1;
                        read_state <= READ_A_REQUEST;

                    end

                end

                //==============================================================
                // B REQUEST
                //==============================================================

                READ_B_REQUEST: begin

                    read_state <= READ_B_WAIT1;

                end

                //==============================================================
                // B WAIT 1
                //==============================================================

                READ_B_WAIT1: begin

                    read_state <= READ_B_WAIT2;

                end

                //==============================================================
                // B WAIT 2 + CAPTURE
                //==============================================================

                READ_B_WAIT2: begin

                    case (read_index)

                        4'd0:
                            captured_b0 <= sparse_b_rdata;

                        4'd1:
                            captured_b1 <= sparse_b_rdata;

                        4'd2:
                            captured_b2 <= sparse_b_rdata;

                        4'd3:
                            captured_b3 <= sparse_b_rdata;

                        4'd4:
                            captured_b4 <= sparse_b_rdata;

                        4'd5:
                            captured_b5 <= sparse_b_rdata;

                        4'd6:
                            captured_b6 <= sparse_b_rdata;

                        4'd7:
                            captured_b7 <= sparse_b_rdata;

                        default:
                            ;

                    endcase

                    if (read_index == 4'd7) begin

                        read_index <= 4'd0;
                        read_state <= READ_META_REQUEST;

                    end

                    else begin

                        read_index <= read_index + 4'd1;
                        read_state <= READ_B_REQUEST;

                    end

                end

                //==============================================================
                // METADATA REQUEST
                //==============================================================

                READ_META_REQUEST: begin

                    read_state <= READ_META_WAIT1;

                end

                //==============================================================
                // METADATA WAIT 1
                //==============================================================

                READ_META_WAIT1: begin

                    read_state <= READ_META_WAIT2;

                end

                //==============================================================
                // METADATA WAIT 2 + CAPTURE
                //==============================================================

                READ_META_WAIT2: begin

                    if (read_index == 4'd0) begin

                        captured_metadata0 <=
                            sparse_metadata_rdata[2:0];

                        read_index <= 4'd1;

                        read_state <= READ_META_REQUEST;

                    end

                    else begin

                        captured_metadata1 <=
                            sparse_metadata_rdata[2:0];

                        read_state <= READ_COMPLETE;

                    end

                end

                //==============================================================
                // All operands captured.
                //==============================================================

                READ_COMPLETE: begin

                    if (compute_request_pending) begin

                        sparse_compute_start <= 1'b1;

                        compute_request_pending <= 1'b0;

                        read_state <= COMPUTE_WAIT;

                    end

                    else begin

                        read_state <= READ_IDLE;

                    end

                    $display(
                        "DEBUG A0=%0d A1=%0d A2=%0d A3=%0d",
                        captured_a0,
                        captured_a1,
                        captured_a2,
                        captured_a3
                    );

                    $display(
                        "DEBUG B0=%0d B1=%0d B2=%0d B3=%0d",
                        captured_b0,
                        captured_b1,
                        captured_b2,
                        captured_b3
                    );

                    $display(
                        "DEBUG B4=%0d B5=%0d B6=%0d B7=%0d",
                        captured_b4,
                        captured_b5,
                        captured_b6,
                        captured_b7
                    );

                    $display(
                        "DEBUG META0=%03b META1=%03b",
                        captured_metadata0,
                        captured_metadata1
                    );

                end

                //==============================================================
                // Compute running
                //==============================================================

                COMPUTE_WAIT: begin

                    if (compute_done) begin

                        read_state <= READ_IDLE;

                    end

                end

                //==============================================================
                // Safety
                //==============================================================

                default: begin

                    read_state <= READ_IDLE;
                    compute_request_pending <= 1'b0;

                end

            endcase

        end

    end

    //==========================================================================
    // Sparse Compute Controller
    //==========================================================================

    logic [15:0] sparse_mac_count;

    sparse_compute_controller #(

        .DATA_WIDTH(32),
        .ACC_WIDTH (64),
        .K_SIZE    (8)

    ) u_sparse_compute_controller (

        .clk(clk),
        .rst(rst),

        .start(
            sparse_compute_start
        ),

        .busy(
            compute_busy
        ),

        .done(
            compute_done
        ),

        //----------------------------------------------------------------------
        // Compressed A
        //----------------------------------------------------------------------

        .sparse_a_value0(
            captured_a0
        ),

        .sparse_a_value1(
            captured_a1
        ),

        .sparse_a_value2(
            captured_a2
        ),

        .sparse_a_value3(
            captured_a3
        ),

        //----------------------------------------------------------------------
        // Dense B
        //----------------------------------------------------------------------

        .b_value0(captured_b0),
        .b_value1(captured_b1),
        .b_value2(captured_b2),
        .b_value3(captured_b3),
        .b_value4(captured_b4),
        .b_value5(captured_b5),
        .b_value6(captured_b6),
        .b_value7(captured_b7),

        //----------------------------------------------------------------------
        // Metadata
        //----------------------------------------------------------------------

        .metadata0(
            captured_metadata0
        ),

        .metadata1(
            captured_metadata1
        ),

        //----------------------------------------------------------------------
        // Result
        //----------------------------------------------------------------------

        .result(
            compute_result
        ),

        //----------------------------------------------------------------------
        // MAC count
        //----------------------------------------------------------------------

        .mac_count(
            sparse_mac_count
        )

    );

    //==========================================================================
    // MAC Count
    //==========================================================================

    always_comb begin

        compute_mac_count = {16'd0, sparse_mac_count};

    end

    //==========================================================================
    // Datapath Status
    //==========================================================================

    always_comb begin

        datapath_busy =
            transfer_busy ||
            compute_busy ||
            (read_state != READ_IDLE);

        datapath_done =
            compute_done;

    end

endmodule

`default_nettype wire