//==============================================================================
//
// Testbench   : sparse_compute_8x8_controller_tb
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   Standalone functional verification of the complete 8x8 sparse compute
//   controller.
//
//   Verifies:
//
//     1. Actual 8x8 2:4 sparse A matrix
//     2. Dense 8x8 B matrix
//     3. Metadata correctness
//     4. All 64 C outputs
//     5. Sparse MAC count = 256
//     6. busy assertion/deassertion
//     7. done assertion
//     8. Accumulator clearing between output elements
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module sparse_compute_8x8_controller_tb;

    //==========================================================================
    // Parameters
    //==========================================================================

    localparam int DATA_WIDTH = 32;
    localparam int ACC_WIDTH  = 64;

    //==========================================================================
    // Clock / Reset
    //==========================================================================

    logic clk;
    logic rst;

    initial begin

        clk = 1'b0;

        forever #5 clk = ~clk;

    end

    //==========================================================================
    // DUT Control
    //==========================================================================

    logic start;
    logic busy;
    logic done;

    //==========================================================================
    // DUT Inputs
    //==========================================================================

    logic signed [DATA_WIDTH-1:0]
        sparse_a [0:7][0:3];

    logic signed [DATA_WIDTH-1:0]
        b [0:7][0:7];

    logic [2:0]
        metadata [0:7][0:1];

    //==========================================================================
    // DUT Outputs
    //==========================================================================

    logic signed [ACC_WIDTH-1:0]
        result [0:7][0:7];

    logic [15:0] mac_count;

    //==========================================================================
    // Software Reference
    //==========================================================================

    longint signed expected [0:7][0:7];

    //==========================================================================
    // Test Statistics
    //==========================================================================

    integer failures;

    integer row;
    integer col;
    integer k;

    integer timeout;

    //==========================================================================
    // DUT
    //==========================================================================

    sparse_compute_8x8_controller #(

        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)

    ) DUT (

        .clk(clk),
        .rst(rst),

        .start(start),

        .busy(busy),
        .done(done),

        .sparse_a(sparse_a),

        .b(b),

        .metadata(metadata),

        .result(result),

        .mac_count(mac_count)

    );

    //==========================================================================
    // Build Test Matrices
    //==========================================================================

    task automatic build_test_data;

        integer r;
        integer c;

        begin

            //==================================================================
            // Dense B
            //
            // B[k][j] = 1 + k*8 + j
            //
            //==================================================================

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 8; c = c + 1) begin

                    b[r][c] = 1 + (r * 8) + c;

                end

            end

            //==================================================================
            // Sparse A
            //
            // Each row has:
            //
            //   group 0 -> two non-zero values
            //   group 1 -> two non-zero values
            //
            // Therefore every row satisfies 2:4.
            //
            //==================================================================

            // Row 0:
            // [10, 0, 0, 20 | 30, 0, 40, 0]
            sparse_a[0][0] = 10;
            sparse_a[0][1] = 20;
            sparse_a[0][2] = 30;
            sparse_a[0][3] = 40;

            // Row 1:
            // [0, 50, 60, 0 | 70, 0, 0, 80]
            sparse_a[1][0] = 50;
            sparse_a[1][1] = 60;
            sparse_a[1][2] = 70;
            sparse_a[1][3] = 80;

            // Row 2:
            // [90, 0, 0, 11 | 12, 13, 0, 0]
            sparse_a[2][0] = 90;
            sparse_a[2][1] = 11;
            sparse_a[2][2] = 12;
            sparse_a[2][3] = 13;

            // Row 3:
            // [0, 14, 15, 0 | 16, 0, 17, 0]
            sparse_a[3][0] = 14;
            sparse_a[3][1] = 15;
            sparse_a[3][2] = 16;
            sparse_a[3][3] = 17;

            // Row 4:
            // [18, 0, 19, 0 | 0, 20, 0, 21]
            sparse_a[4][0] = 18;
            sparse_a[4][1] = 19;
            sparse_a[4][2] = 20;
            sparse_a[4][3] = 21;

            // Row 5:
            // [0, 22, 23, 0 | 24, 25, 0, 0]
            sparse_a[5][0] = 22;
            sparse_a[5][1] = 23;
            sparse_a[5][2] = 24;
            sparse_a[5][3] = 25;

            // Row 6:
            // [26, 27, 0, 0 | 0, 28, 29, 0]
            sparse_a[6][0] = 26;
            sparse_a[6][1] = 27;
            sparse_a[6][2] = 28;
            sparse_a[6][3] = 29;

            // Row 7:
            // [0, 31, 32, 0 | 33, 0, 0, 34]
            sparse_a[7][0] = 31;
            sparse_a[7][1] = 32;
            sparse_a[7][2] = 33;
            sparse_a[7][3] = 34;

            //==================================================================
            // Metadata
            //
            // Encoding:
            //
            // 000 -> positions 0,1
            // 001 -> positions 0,2
            // 010 -> positions 0,3
            // 011 -> positions 1,2
            // 100 -> positions 1,3
            // 101 -> positions 2,3
            //==================================================================

            // Row 0:
            // [10,0,0,20] -> 010
            // [30,0,40,0] -> 001
            metadata[0][0] = 3'b010;
            metadata[0][1] = 3'b001;

            // Row 1:
            // [0,50,60,0] -> 011
            // [70,0,0,80] -> 100
            metadata[1][0] = 3'b011;
            metadata[1][1] = 3'b100;

            // Row 2:
            // [90,0,0,11] -> 010
            // [12,13,0,0] -> 000
            metadata[2][0] = 3'b010;
            metadata[2][1] = 3'b000;

            // Row 3:
            // [0,14,15,0] -> 011
            // [16,0,17,0] -> 001
            metadata[3][0] = 3'b011;
            metadata[3][1] = 3'b001;

            // Row 4:
            // [18,0,19,0] -> 001
            // [0,20,0,21] -> 100
            metadata[4][0] = 3'b001;
            metadata[4][1] = 3'b100;

            // Row 5:
            // [0,22,23,0] -> 011
            // [24,25,0,0] -> 000
            metadata[5][0] = 3'b011;
            metadata[5][1] = 3'b000;

            // Row 6:
            // [26,27,0,0] -> 000
            // [0,28,29,0] -> 011
            metadata[6][0] = 3'b000;
            metadata[6][1] = 3'b011;

            // Row 7:
            // [0,31,32,0] -> 011
            // [33,0,0,34] -> 010
            metadata[7][0] = 3'b011;
            metadata[7][1] = 3'b010;

        end

    endtask

    //==========================================================================
    // Build Reference Result
    //==========================================================================

    task automatic build_reference;

        integer r;
        integer c;
        integer kk;
        integer group;
        integer base_k;
        integer index_a;
        integer compressed_index;

        longint signed a_value;

        begin

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 8; c = c + 1) begin

                    expected[r][c] = 0;

                    for (group = 0; group < 2; group = group + 1) begin

                        if (group == 0)
                            base_k = 0;
                        else
                            base_k = 4;

                        //------------------------------------------------------------------
                        // First non-zero index
                        //------------------------------------------------------------------

                        case (metadata[r][group])

                            3'b000: index_a = 0;
                            3'b001: index_a = 0;
                            3'b010: index_a = 0;
                            3'b011: index_a = 1;
                            3'b100: index_a = 1;
                            3'b101: index_a = 2;

                            default: index_a = 0;

                        endcase

                        if (group == 0)
                            compressed_index = 0;
                        else
                            compressed_index = 2;

                        a_value =
                            sparse_a[r][compressed_index];

                        expected[r][c] =
                            expected[r][c] +
                            a_value *
                            b[base_k + index_a][c];

                        //------------------------------------------------------------------
                        // Second non-zero index
                        //------------------------------------------------------------------

                        case (metadata[r][group])

                            3'b000: index_a = 1;
                            3'b001: index_a = 2;
                            3'b010: index_a = 3;
                            3'b011: index_a = 2;
                            3'b100: index_a = 3;
                            3'b101: index_a = 3;

                            default: index_a = 0;

                        endcase

                        if (group == 0)
                            compressed_index = 1;
                        else
                            compressed_index = 3;

                        a_value =
                            sparse_a[r][compressed_index];

                        expected[r][c] =
                            expected[r][c] +
                            a_value *
                            b[base_k + index_a][c];

                    end

                end

            end

        end

    endtask

    //==========================================================================
    // Print Matrix
    //==========================================================================

    task automatic print_input;

        integer r;
        integer c;

        begin

            $display("");
            $display("----------------------------------------------");
            $display("8x8 SPARSE TEST INPUT");
            $display("----------------------------------------------");

            $display("");
            $display("Compressed A + metadata:");

            for (r = 0; r < 8; r = r + 1) begin

                $display(
                    "Row %0d : A=[%0d,%0d,%0d,%0d] META=[%03b,%03b]",
                    r,
                    sparse_a[r][0],
                    sparse_a[r][1],
                    sparse_a[r][2],
                    sparse_a[r][3],
                    metadata[r][0],
                    metadata[r][1]
                );

            end

            $display("");
            $display("Dense B:");

            for (r = 0; r < 8; r = r + 1) begin

                $display(
                    "[%0d %0d %0d %0d %0d %0d %0d %0d]",
                    b[r][0],
                    b[r][1],
                    b[r][2],
                    b[r][3],
                    b[r][4],
                    b[r][5],
                    b[r][6],
                    b[r][7]
                );

            end

        end

    endtask

    //==========================================================================
    // Print Expected Result
    //==========================================================================

    task automatic print_expected;

        integer r;
        integer c;

        begin

            $display("");
            $display("----------------------------------------------");
            $display("EXPECTED C");
            $display("----------------------------------------------");

            for (r = 0; r < 8; r = r + 1) begin

                $write("[");

                for (c = 0; c < 8; c = c + 1) begin

                    $write("%0d", expected[r][c]);

                    if (c != 7)
                        $write(" ");

                end

                $display("]");

            end

        end

    endtask

    //==========================================================================
    // Check Results
    //==========================================================================

    task automatic check_results;

        integer r;
        integer c;

        begin

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 8; c = c + 1) begin

                    if (result[r][c] !== expected[r][c]) begin

                        failures = failures + 1;

                        $display(
                            "[FAIL] C[%0d][%0d] Expected=%0d Observed=%0d",
                            r,
                            c,
                            expected[r][c],
                            result[r][c]
                        );

                    end

                    else begin

                        $display(
                            "[PASS] C[%0d][%0d] = %0d",
                            r,
                            c,
                            result[r][c]
                        );

                    end

                end

            end

        end

    endtask

    //==========================================================================
    // Main Test
    //==========================================================================

    initial begin

        failures = 0;

        start = 1'b0;
        rst   = 1'b1;

        // Initialize arrays.
        for (row = 0; row < 8; row = row + 1) begin

            for (col = 0; col < 8; col = col + 1) begin

                b[row][col] = '0;

            end

            for (col = 0; col < 4; col = col + 1)
                sparse_a[row][col] = '0;

            for (col = 0; col < 2; col = col + 1)
                metadata[row][col] = '0;

        end

        //----------------------------------------------------------------------
        // Reset
        //----------------------------------------------------------------------

        repeat (3)
            @(posedge clk);

        rst = 1'b0;

        @(posedge clk);

        //----------------------------------------------------------------------
        // Build workload
        //----------------------------------------------------------------------

        build_test_data();
        build_reference();

        print_input();
        print_expected();

        //----------------------------------------------------------------------
        // Start
        //----------------------------------------------------------------------

        $display("");
        $display("==============================================");
        $display("SPARSE 8x8 COMPUTE TEST");
        $display("==============================================");

        $display("");
        $display("Starting sparse 8x8 computation...");

        start = 1'b1;

        @(posedge clk);
        #1;

        start = 1'b0;

        //----------------------------------------------------------------------
        // Verify busy
        //----------------------------------------------------------------------

        @(posedge clk);

        if (busy !== 1'b1) begin

            failures = failures + 1;

            $display("[FAIL] busy was not asserted");

        end

        else begin

            $display("[PASS] busy asserted");

        end

        //----------------------------------------------------------------------
        // Wait for done with timeout
        //----------------------------------------------------------------------

        timeout = 0;

        while (!done) begin

            @(posedge clk);
            #1;

            timeout = timeout + 1;

            if (timeout > 1000) begin

                failures = failures + 1;

                $display("[FAIL] COMPUTE TIMEOUT");

                $finish;

            end

        end

        //----------------------------------------------------------------------
        // Check completion
        //----------------------------------------------------------------------

        $display("");
        $display("----------------------------------------------");
        $display("COMPUTE COMPLETE");
        $display("----------------------------------------------");

        if (done !== 1'b1) begin

            failures = failures + 1;

            $display("[FAIL] done not asserted");

        end

        else begin

            $display("[PASS] done asserted");

        end

        //----------------------------------------------------------------------
        // Check MAC count
        //
        // 8 rows x 8 columns x 4 sparse MACs
        // = 256
        //----------------------------------------------------------------------

        if (mac_count !== 16'd256) begin

            failures = failures + 1;

            $display(
                "[FAIL] MAC count expected 256, observed %0d",
                mac_count
            );

        end

        else begin

            $display("[PASS] MAC count = 256");

        end

        //----------------------------------------------------------------------
        // Check busy deassertion
        //----------------------------------------------------------------------

        @(posedge clk);
        #1;

        if (busy !== 1'b0) begin

            failures = failures + 1;

            $display("[FAIL] busy did not deassert");

        end

        else begin

            $display("[PASS] busy deasserted");

        end

        //----------------------------------------------------------------------
        // Check every output
        //----------------------------------------------------------------------

        $display("");
        $display("----------------------------------------------");
        $display("RESULT VERIFICATION");
        $display("----------------------------------------------");

        check_results();

        //----------------------------------------------------------------------
        // Final result
        //----------------------------------------------------------------------

        $display("");
        $display("==============================================");

        if (failures == 0) begin

            $display("SPARSE 8x8 CONTROLLER TEST PASSED");

        end

        else begin

            $display(
                "SPARSE 8x8 CONTROLLER TEST FAILED: %0d failures",
                failures
            );

        end

        $display("==============================================");

        $finish;

    end

endmodule

`default_nettype wire