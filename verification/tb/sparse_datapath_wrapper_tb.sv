//==============================================================================
// Testbench : sparse_datapath_wrapper_tb
//
// Purpose:
//   End-to-end smoke test of the current sparse datapath.
//
// Tested path:
//
//   Main Memory
//       ↓
//   Transfer Engine
//       ↓
//   Scratchpad Controller
//       ↓
//   Scratchpad
//       ↓
//   Sparse Compute Controller
//       ↓
//   Result
//
// Current scope:
//   One 8-element K sparse operation.
//
// Expected sparse operation:
//
//   A compressed:
//       A0 = 10
//       A1 = 20
//       A2 = 30
//       A3 = 40
//
//   Metadata:
//       000 -> logical positions (0,1)
//       101 -> logical positions (2,3)
//
//   Therefore:
//
//       Group 0:
//           10 * B0
//         + 20 * B1
//
//       Group 1:
//           30 * B6
//         + 40 * B7
//
//   B:
//
//       B0 = 1
//       B1 = 2
//       B2 = 3
//       B3 = 4
//       B4 = 5
//       B5 = 6
//       B6 = 7
//       B7 = 8
//
//   Expected:
//
//       10*1 + 20*2 + 30*7 + 40*8
//       = 10 + 40 + 210 + 320
//       = 580
//
//   Expected MAC count = 4
//==============================================================================

`timescale 1ns/1ps

import tile_pkg::*;

module sparse_datapath_wrapper_tb;

    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------

    localparam integer CLK_PERIOD = 10;

    logic clk;
    logic rst;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //--------------------------------------------------------------------------
    // Sparse request
    //--------------------------------------------------------------------------

    sparse_tile_request_t sparse_tile_request;
    logic sparse_tile_request_valid;
    logic sparse_tile_request_ready;

    //--------------------------------------------------------------------------
    // Main memory interface
    //--------------------------------------------------------------------------

    logic        mem_req_valid;
    logic        mem_req_ready;
    logic [31:0] mem_req_addr;
    logic [31:0] mem_req_bytes;

    logic        mem_rvalid;
    logic [63:0] mem_rdata;
    logic        mem_rlast;

    //--------------------------------------------------------------------------
    // Compute control
    //--------------------------------------------------------------------------

    logic compute_start;

    logic compute_busy;
    logic compute_done;

    logic signed [63:0] compute_result;
    logic [31:0] compute_mac_count;

    logic transfer_busy;
    logic transfer_done;

    logic datapath_busy;
    logic datapath_done;

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------

    sparse_datapath_wrapper DUT (

        .clk(clk),
        .rst(rst),

        .sparse_tile_request(
            sparse_tile_request
        ),
        .sparse_tile_request_valid(
            sparse_tile_request_valid
        ),
        .sparse_tile_request_ready(
            sparse_tile_request_ready
        ),

        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr),
        .mem_req_bytes(mem_req_bytes),

        .mem_rvalid(mem_rvalid),
        .mem_rdata(mem_rdata),
        .mem_rlast(mem_rlast),

        .compute_start(compute_start),

        .compute_busy(compute_busy),
        .compute_done(compute_done),

        .compute_result(compute_result),
        .compute_mac_count(compute_mac_count),

        .transfer_busy(transfer_busy),
        .transfer_done(transfer_done),

        .datapath_busy(datapath_busy),
        .datapath_done(datapath_done)
    );

    //==========================================================================
    // Simple Main Memory Model
    //
    // The memory returns deterministic 64-bit beats.
    //
    // A = 2 beats
    // B = 4 beats
    // Metadata = 2 beats
    //
    // The values are packed into 32-bit words because the scratchpad
    // controller splits each 64-bit beat into two 32-bit words.
    //==========================================================================

    integer beat_index;
    integer memory_phase;

    logic memory_active;

    assign mem_req_ready = 1'b1;

    always_ff @(posedge clk) begin

        if (rst) begin

            mem_rvalid    <= 1'b0;
            mem_rdata     <= 64'd0;
            mem_rlast     <= 1'b0;

            beat_index    <= 0;
            memory_phase  <= 0;
            memory_active <= 1'b0;
        end
        else begin

            mem_rvalid <= 1'b0;
            mem_rlast  <= 1'b0;

            //------------------------------------------------------------------
            // Accept new memory request
            //------------------------------------------------------------------

            if (mem_req_valid && mem_req_ready) begin

                memory_active <= 1'b1;
                beat_index    <= 0;

                if (mem_req_addr == 32'h1000_0000)
                    memory_phase <= 0;       // A

                else if (mem_req_addr == 32'h2000_0000)
                    memory_phase <= 1;       // B

                else if (mem_req_addr == 32'h3000_0000)
                    memory_phase <= 2;       // Metadata

                else
                    memory_phase <= 3;
            end

            //------------------------------------------------------------------
            // Stream memory data
            //------------------------------------------------------------------

            else if (memory_active) begin

                mem_rvalid <= 1'b1;

                case (memory_phase)

                    //==========================================================
                    // Compressed A
                    //
                    // Beat 0:
                    //   word 0 = 10
                    //   word 1 = 20
                    //
                    // Beat 1:
                    //   word 2 = 30
                    //   word 3 = 40
                    //==========================================================

                    0: begin

                        case (beat_index)

                            0:
                                mem_rdata <=
                                    {32'd20,32'd10};

                            1:
                                mem_rdata <=
                                    {32'd40,32'd30};

                            default:
                                mem_rdata <= 64'd0;

                        endcase

                        if (beat_index == 1)
                            mem_rlast <= 1'b1;

                    end

                    //==========================================================
                    // Dense B
                    //
                    // Beat 0: B0 B1
                    // Beat 1: B2 B3
                    // Beat 2: B4 B5
                    // Beat 3: B6 B7
                    //==========================================================

                    1: begin

                        case (beat_index)

                            0:
                                mem_rdata <=
                                    {32'd2,32'd1};

                            1:
                                mem_rdata <=
                                    {32'd4,32'd3};

                            2:
                                mem_rdata <=
                                    {32'd6,32'd5};

                            3:
                                mem_rdata <=
                                    {32'd8,32'd7};

                            default:
                                mem_rdata <= 64'd0;

                        endcase

                        if (beat_index == 3)
                            mem_rlast <= 1'b1;

                    end

                    //==========================================================
                    // Metadata
                    //
                    // Metadata word 0 = 000
                    // Metadata word 1 = 101
                    //
                    // Remaining words are unused in this one-output test.
                    //==========================================================

                    2: begin

                        case (beat_index)

                            0:
                                mem_rdata <=
                                    {32'd0,32'b000};

                            1:
                                mem_rdata <=
                                    {32'd0,32'b101};

                            default:
                                mem_rdata <= 64'd0;

                        endcase

                        if (beat_index == 1)
                            mem_rlast <= 1'b1;

                    end

                    default: begin
                        mem_rdata <= 64'd0;
                        mem_rlast <= 1'b1;
                    end

                endcase

                //----------------------------------------------------------------
                // End current burst
                //----------------------------------------------------------------

                if (mem_rlast) begin
                    memory_active <= 1'b0;
                    beat_index    <= 0;
                end
                else begin
                    beat_index <= beat_index + 1;
                end

            end
        end
    end

    //==========================================================================
    // Test
    //==========================================================================

    initial begin

        sparse_tile_request = '0;
        sparse_tile_request_valid = 1'b0;
        compute_start = 1'b0;

        rst = 1'b1;

        repeat (5)
            @(posedge clk);

        rst = 1'b0;

        repeat (2)
            @(posedge clk);

        //======================================================================
        // Construct sparse request
        //======================================================================

        sparse_tile_request = '0;

        sparse_tile_request.valid     = 1'b1;
        sparse_tile_request.last_tile = 1'b1;

        sparse_tile_request.tile_context.tile_row = 16'd0;
        sparse_tile_request.tile_context.tile_col = 16'd0;
        sparse_tile_request.tile_context.tile_k   = 16'd0;

        sparse_tile_request.values_addr_a =
            32'h1000_0000;

        sparse_tile_request.values_addr_b =
            32'h2000_0000;

        sparse_tile_request.metadata_addr_a =
            32'h3000_0000;

        sparse_tile_request.addr_c =
            32'h4000_0000;

        sparse_tile_request.rows   = 16'd8;
        sparse_tile_request.cols   = 16'd8;
        sparse_tile_request.k_size = 16'd8;

        sparse_tile_request.stride_a = 16'd8;
        sparse_tile_request.stride_b = 16'd8;

        sparse_tile_request.bank_a = 4'd0;
        sparse_tile_request.bank_b = 4'd1;
        sparse_tile_request.bank_c = 4'd2;

        sparse_tile_request.metadata_bank = 4'd2;

        // Four compressed 32-bit A values.
        sparse_tile_request.transfer_bytes_a = 32'd16;

        // Eight 32-bit B values.
        sparse_tile_request.transfer_bytes_b = 32'd32;

        // Two metadata words transferred for this integration test.
        sparse_tile_request.metadata_transfer_bytes = 32'd16;

        //======================================================================
        // Submit sparse tile
        //======================================================================

        @(posedge clk);

        while (!sparse_tile_request_ready)
            @(posedge clk);

        sparse_tile_request_valid <= 1'b1;

        @(posedge clk);

        sparse_tile_request_valid <= 1'b0;

        $display("");
        $display("==============================================");
        $display("SPARSE DATAPATH WRAPPER TEST");
        $display("==============================================");

        //======================================================================
        // Wait for transfer
        //======================================================================

        wait (transfer_done);

        $display("----------------------------------------------");
        $display("Transfer completed");
        $display("----------------------------------------------");

        //======================================================================
        // Start compute
        //======================================================================

        @(posedge clk);

        compute_start <= 1'b1;

        @(posedge clk);

        compute_start <= 1'b0;

        //======================================================================
        // Wait for compute
        //======================================================================

        wait (compute_done);

        $display("----------------------------------------------");
        $display("Sparse compute completed");
        $display("----------------------------------------------");

        $display("Result     : %0d", compute_result);
        $display("MAC count  : %0d", compute_mac_count);

        //======================================================================
        // Checks
        //======================================================================

        if (compute_result == 64'sd580)
            $display("PASS: Sparse result = 580");
        else
            $display(
                "FAIL: Sparse result expected 580, got %0d",
                compute_result
            );

        if (compute_mac_count == 32'd4)
            $display("PASS: MAC count = 4");
        else
            $display(
                "FAIL: MAC count expected 4, got %0d",
                compute_mac_count
            );

        if (!compute_busy)
            $display("PASS: Compute busy deasserted");
        else
            $display("FAIL: Compute busy still asserted");

        $display("");
        $display("==============================================");
        $display("SPARSE DATAPATH WRAPPER TEST COMPLETE");
        $display("==============================================");

        #20;

        $finish;

    end

endmodule