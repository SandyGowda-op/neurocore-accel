`timescale 1ns/1ps
`default_nettype none

import tile_pkg::*;

module sparse_subsystem_8x8_tb;

    //======================================================================
    // Parameters
    //======================================================================

    localparam integer CLK_PERIOD  = 10;
    localparam integer MATRIX_DIM  = 8;
    localparam integer NUM_RESULTS = 64;

    //======================================================================
    // Clock / Reset
    //======================================================================

    logic clk;
    logic rst;

    initial begin
        clk = 1'b0;

        forever #(CLK_PERIOD / 2)
            clk = ~clk;
    end

    //======================================================================
    // Sparse Tile Request
    //======================================================================

    sparse_tile_request_t sparse_tile_request;

    logic sparse_tile_request_valid;
    logic sparse_tile_request_ready;

    //======================================================================
    // Compute Control
    //======================================================================

    logic compute_start;

    logic compute_busy;
    logic compute_done;

    logic signed [63:0] compute_result [0:7][0:7];

    logic [31:0] compute_mac_count;

    //======================================================================
    // Status
    //======================================================================

    logic transfer_busy;
    logic transfer_done;

    logic datapath_busy;
    logic datapath_done;

    //======================================================================
    // DUT
    //
    // sparse_subsystem_8x8 contains:
    //
    //     sparse_datapath_8x8_wrapper
    //                 |
    //                 v
    //     main_memory_model
    //
    // The TB therefore checks actual memory -> datapath integration.
    //======================================================================

    sparse_subsystem_8x8 #(
        .BURST_BYTES      (128),
        .DATA_WIDTH       (64),
        .SPAD_DATA_WIDTH  (32),
        .SPAD_ADDR_WIDTH  (6)
    ) dut (

        .clk(
            clk
        ),

        .rst(
            rst
        ),

        .sparse_tile_request(
            sparse_tile_request
        ),

        .sparse_tile_request_valid(
            sparse_tile_request_valid
        ),

        .sparse_tile_request_ready(
            sparse_tile_request_ready
        ),

        .compute_start(
            compute_start
        ),

        .compute_busy(
            compute_busy
        ),

        .compute_done(
            compute_done
        ),

        .compute_result(
            compute_result
        ),

        .compute_mac_count(
            compute_mac_count
        ),

        .transfer_busy(
            transfer_busy
        ),

        .transfer_done(
            transfer_done
        ),

        .datapath_busy(
            datapath_busy
        ),

        .datapath_done(
            datapath_done
        )

    );

    //======================================================================
    // Expected Result Matrix
    //
    // This is the SAME expected C matrix used by the already-verified
    // standalone sparse datapath TB.
    //
    // We are therefore testing whether moving the data source from the
    // standalone TB stimulus into main_memory_model preserves correctness.
    //======================================================================

    integer EXPECTED_C [0:7][0:7];

    task automatic initialize_expected;

        begin

            EXPECTED_C[0][0] = 3460;
            EXPECTED_C[0][1] = 3560;
            EXPECTED_C[0][2] = 3660;
            EXPECTED_C[0][3] = 3760;
            EXPECTED_C[0][4] = 3860;
            EXPECTED_C[0][5] = 3960;
            EXPECTED_C[0][6] = 4060;
            EXPECTED_C[0][7] = 4160;

            EXPECTED_C[1][0] = 8900;
            EXPECTED_C[1][1] = 9160;
            EXPECTED_C[1][2] = 9420;
            EXPECTED_C[1][3] = 9680;
            EXPECTED_C[1][4] = 9940;
            EXPECTED_C[1][5] = 10200;
            EXPECTED_C[1][6] = 10460;
            EXPECTED_C[1][7] = 10720;

            EXPECTED_C[2][0] = 1294;
            EXPECTED_C[2][1] = 1420;
            EXPECTED_C[2][2] = 1546;
            EXPECTED_C[2][3] = 1672;
            EXPECTED_C[2][4] = 1798;
            EXPECTED_C[2][5] = 1924;
            EXPECTED_C[2][6] = 2050;
            EXPECTED_C[2][7] = 2176;

            EXPECTED_C[3][0] = 1742;
            EXPECTED_C[3][1] = 1804;
            EXPECTED_C[3][2] = 1866;
            EXPECTED_C[3][3] = 1928;
            EXPECTED_C[3][4] = 1990;
            EXPECTED_C[3][5] = 2052;
            EXPECTED_C[3][6] = 2114;
            EXPECTED_C[3][7] = 2176;

            EXPECTED_C[4][0] = 2358;
            EXPECTED_C[4][1] = 2436;
            EXPECTED_C[4][2] = 2514;
            EXPECTED_C[4][3] = 2592;
            EXPECTED_C[4][4] = 2670;
            EXPECTED_C[4][5] = 2748;
            EXPECTED_C[4][6] = 2826;
            EXPECTED_C[4][7] = 2904;

            EXPECTED_C[5][0] = 2406;
            EXPECTED_C[5][1] = 2500;
            EXPECTED_C[5][2] = 2594;
            EXPECTED_C[5][3] = 2688;
            EXPECTED_C[5][4] = 2782;
            EXPECTED_C[5][5] = 2876;
            EXPECTED_C[5][6] = 2970;
            EXPECTED_C[5][7] = 3064;

            EXPECTED_C[6][0] = 2838;
            EXPECTED_C[6][1] = 2948;
            EXPECTED_C[6][2] = 3058;
            EXPECTED_C[6][3] = 3168;
            EXPECTED_C[6][4] = 3278;
            EXPECTED_C[6][5] = 3388;
            EXPECTED_C[6][6] = 3498;
            EXPECTED_C[6][7] = 3608;

            EXPECTED_C[7][0] = 3850;
            EXPECTED_C[7][1] = 3980;
            EXPECTED_C[7][2] = 4110;
            EXPECTED_C[7][3] = 4240;
            EXPECTED_C[7][4] = 4370;
            EXPECTED_C[7][5] = 4500;
            EXPECTED_C[7][6] = 4630;
            EXPECTED_C[7][7] = 4760;

        end

    endtask

    //======================================================================
    // Build Sparse Tile Request
    //======================================================================

    task automatic build_sparse_request;

        begin

            sparse_tile_request = '0;

            //------------------------------------------------------------------
            // Control
            //------------------------------------------------------------------

            sparse_tile_request.valid =
                1'b1;

            sparse_tile_request.last_tile =
                1'b1;

            //------------------------------------------------------------------
            // Tile context
            //------------------------------------------------------------------

            sparse_tile_request.tile_context.tile_row =
                16'd0;

            sparse_tile_request.tile_context.tile_col =
                16'd0;

            sparse_tile_request.tile_context.tile_k =
                16'd0;

            //------------------------------------------------------------------
            // Matrix A
            //
            // Compressed A values.
            //------------------------------------------------------------------

            sparse_tile_request.values_addr_a =
                32'h1000_0000;

            //------------------------------------------------------------------
            // Matrix B
            //------------------------------------------------------------------

            sparse_tile_request.values_addr_b =
                32'h1000_0100;

            //------------------------------------------------------------------
            // Sparse metadata
            //------------------------------------------------------------------

            sparse_tile_request.metadata_addr_a =
                32'h1000_0200;

            //------------------------------------------------------------------
            // Destination
            //------------------------------------------------------------------

            sparse_tile_request.addr_c =
                32'h1000_0300;

            //------------------------------------------------------------------
            // Tile dimensions
            //------------------------------------------------------------------

            sparse_tile_request.rows =
                16'd8;

            sparse_tile_request.cols =
                16'd8;

            sparse_tile_request.k_size =
                16'd8;

            //------------------------------------------------------------------
            // Strides
            //
            // 8 elements × 4 bytes = 32 bytes per row.
            //------------------------------------------------------------------

            sparse_tile_request.stride_a =
                16'd32;

            sparse_tile_request.stride_b =
                16'd32;

            //------------------------------------------------------------------
            // Scratchpad banks
            //------------------------------------------------------------------

            sparse_tile_request.bank_a =
                4'd0;

            sparse_tile_request.bank_b =
                4'd1;

            sparse_tile_request.bank_c =
                4'd3;

            sparse_tile_request.metadata_bank =
                4'd2;

            //------------------------------------------------------------------
            // Transfer sizes
            //
            // A compressed:
            //
            // 8x8 with 2:4 sparsity
            // = 256 bits = 32 bytes
            //
            // However, the current verified sparse datapath transfer setup
            // uses the values stored in the sparse memory image. Therefore
            // use the transfer sizes expected by the current datapath.
            //------------------------------------------------------------------

            sparse_tile_request.transfer_bytes_a =
                32'd128;

            sparse_tile_request.transfer_bytes_b =
                32'd256;

            sparse_tile_request.metadata_transfer_bytes =
                32'd64;

        end

    endtask

    //======================================================================
    // Reset
    //======================================================================

    task automatic reset_dut;

        begin

            rst = 1'b1;

            sparse_tile_request =
                '0;

            sparse_tile_request_valid =
                1'b0;

            compute_start =
                1'b0;

            repeat (5)
                @(posedge clk);

            rst = 1'b0;

            @(posedge clk);

        end

    endtask

    //======================================================================
    // Send Sparse Request
    //======================================================================

    task automatic send_sparse_request;

        integer timeout;

        begin

            build_sparse_request();

            @(posedge clk);

            sparse_tile_request_valid =
                1'b1;

            timeout = 0;

            //--------------------------------------------------------------
            // Wait for ready.
            //--------------------------------------------------------------

            while (!sparse_tile_request_ready) begin

                @(posedge clk);

                timeout = timeout + 1;

                if (timeout > 1000) begin

                    $display(
                        "[FAIL] Timeout waiting for sparse request ready"
                    );

                    $finish;

                end

            end

            //--------------------------------------------------------------
            // Request handshake.
            //--------------------------------------------------------------

            @(posedge clk);

            sparse_tile_request_valid =
                1'b0;

            $display(
                "[PASS] Sparse request accepted"
            );

        end

    endtask

    //======================================================================
    // Wait for Transfer
    //======================================================================

    task automatic wait_for_transfer;

        integer timeout;

        begin

            timeout = 0;

            //--------------------------------------------------------------
            // Wait for transfer_busy.
            //--------------------------------------------------------------

            while (!transfer_busy) begin

                @(posedge clk);

                timeout = timeout + 1;

                if (timeout > 3000) begin

                    $display(
                        "[FAIL] Timeout waiting for transfer_busy"
                    );

                    $finish;

                end

            end

            $display(
                "[PASS] Main-memory transfer started"
            );

            //--------------------------------------------------------------
            // Wait for transfer_done.
            //--------------------------------------------------------------

            timeout = 0;

            while (!transfer_done) begin

                @(posedge clk);

                timeout = timeout + 1;

                if (timeout > 10000) begin

                    $display(
                        "[FAIL] Timeout waiting for transfer_done"
                    );

                    $finish;

                end

            end

            $display(
                "[PASS] Main-memory transfer completed"
            );

        end

    endtask

    //======================================================================
    // Start Compute
    //======================================================================

    task automatic start_compute;

        begin

            @(posedge clk);

            compute_start =
                1'b1;

            @(posedge clk);

            compute_start =
                1'b0;

            $display(
                "[INFO] Sparse compute requested"
            );

        end

    endtask

    //======================================================================
    // Wait for Compute
    //======================================================================

    task automatic wait_for_compute;

        integer timeout;

        begin

            timeout = 0;

            //--------------------------------------------------------------
            // Wait for compute_busy.
            //--------------------------------------------------------------

            while (!compute_busy) begin

                @(posedge clk);

                timeout = timeout + 1;

                if (timeout > 3000) begin

                    $display(
                        "[FAIL] Timeout waiting for compute_busy"
                    );

                    $finish;

                end

            end

            $display(
                "[PASS] Sparse compute started"
            );

            //--------------------------------------------------------------
            // Wait for compute_done.
            //--------------------------------------------------------------

            timeout = 0;

            while (!compute_done) begin

                @(posedge clk);

                timeout = timeout + 1;

                if (timeout > 15000) begin

                    $display(
                        "[FAIL] Timeout waiting for compute_done"
                    );

                    $finish;

                end

            end

            $display(
                "[PASS] Sparse compute completed"
            );

        end

    endtask

    //======================================================================
    // Verify Results
    //======================================================================

    task automatic verify_results;

        integer r;
        integer c;
        integer errors;

        begin

            errors = 0;

            $display("");
            $display("============================================================");
            $display("        SPARSE 8x8 MEMORY-INTEGRATION VERIFICATION");
            $display("============================================================");

            //--------------------------------------------------------------
            // Check C.
            //--------------------------------------------------------------

            for (r = 0; r < MATRIX_DIM; r = r + 1) begin

                for (c = 0; c < MATRIX_DIM; c = c + 1) begin

                    if (compute_result[r][c] !==
                        EXPECTED_C[r][c]) begin

                        $display(
                            "[FAIL] C[%0d][%0d] expected=%0d got=%0d",
                            r,
                            c,
                            EXPECTED_C[r][c],
                            compute_result[r][c]
                        );

                        errors = errors + 1;

                    end
                    else begin

                        $display(
                            "[PASS] C[%0d][%0d] = %0d",
                            r,
                            c,
                            compute_result[r][c]
                        );

                    end

                end

            end
            

            //--------------------------------------------------------------
            // Check sparse MAC count.
            //--------------------------------------------------------------

            if (compute_mac_count == 256) begin

                $display(
                    "[PASS] Sparse MAC count = 256"
                );

            end
            else begin

                $display(
                    "[FAIL] Sparse MAC count expected=256 got=%0d",
                    compute_mac_count
                );

                errors = errors + 1;

            end

            //--------------------------------------------------------------
            // Final status.
            //--------------------------------------------------------------

            $display("");

            if (errors == 0) begin

                $display(
                    "SPARSE 8x8 MEMORY-INTEGRATION FUNCTIONAL TEST : PASS"
                );

            end
            else begin

                $display(
                    "SPARSE 8x8 MEMORY-INTEGRATION FUNCTIONAL TEST : FAIL"
                );

                $display(
                    "Functional errors = %0d",
                    errors
                );

            end

            $display("============================================================");
            $display("");

        end

    endtask

    //======================================================================
    // Main Test
    //======================================================================

    initial begin

        $display("");
        $display("============================================================");
        $display("       SPARSE 8x8 MAIN-MEMORY INTEGRATION TEST");
        $display("============================================================");
        $display("");

        //--------------------------------------------------------------
        // Initialize expected C.
        //--------------------------------------------------------------

        initialize_expected();

        //--------------------------------------------------------------
        // Reset.
        //--------------------------------------------------------------

        reset_dut();

        //--------------------------------------------------------------
        // Submit sparse tile request.
        //--------------------------------------------------------------

        send_sparse_request();

        //--------------------------------------------------------------
        // Allow transfer engine to fetch:
        //
        //     A
        //     B
        //     META
        //
        //--------------------------------------------------------------

        wait_for_transfer();

        //--------------------------------------------------------------
        // Start compute after transfer completion.
        //--------------------------------------------------------------

        start_compute();

        //--------------------------------------------------------------
        // Wait for sparse computation.
        //--------------------------------------------------------------

        wait_for_compute();

        //--------------------------------------------------------------
        // Give output signals one cycle to settle.
        //--------------------------------------------------------------

        @(posedge clk);

        //--------------------------------------------------------------
        // Verify C.
        //--------------------------------------------------------------

        verify_results();

        $finish;

    end


    always @(posedge clk) begin

    if (dut.u_sparse.te_spad_write_enable) begin

        $display(
            "[TB-SPAD-WRITE] t=%0t bank=%0d addr=%0d data=%016h",
            $time,
            dut.u_sparse.te_spad_bank,
            dut.u_sparse.te_spad_address,
            dut.u_sparse.te_spad_write_data
        );

    end

end

endmodule

`default_nettype wire