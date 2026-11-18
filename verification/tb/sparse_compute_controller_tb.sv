//==============================================================================
// Testbench  : sparse_compute_controller_tb
// Project    : Descriptor-Driven RISC-V AI Accelerator
//
// Purpose:
//   Verify the sparse compute datapath independently before integration.
//
// Checks:
//   1. Correct 2:4 metadata interpretation
//   2. Correct sparse A / dense B pairing
//   3. Correct accumulated result
//   4. Exactly 4 MAC operations for K=8
//   5. Busy / done behavior
//   6. Accumulator clears correctly between operations
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module sparse_compute_controller_tb;

    //==========================================================================
    // Parameters
    //==========================================================================

    localparam int DATA_WIDTH = 32;
    localparam int ACC_WIDTH  = 64;
    localparam int K_SIZE     = 8;

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
    // Sparse A Values
    //==========================================================================

    logic signed [DATA_WIDTH-1:0] sparse_a_value0;
    logic signed [DATA_WIDTH-1:0] sparse_a_value1;
    logic signed [DATA_WIDTH-1:0] sparse_a_value2;
    logic signed [DATA_WIDTH-1:0] sparse_a_value3;

    //==========================================================================
    // Dense B Values
    //==========================================================================

    logic signed [DATA_WIDTH-1:0] b_value0;
    logic signed [DATA_WIDTH-1:0] b_value1;
    logic signed [DATA_WIDTH-1:0] b_value2;
    logic signed [DATA_WIDTH-1:0] b_value3;
    logic signed [DATA_WIDTH-1:0] b_value4;
    logic signed [DATA_WIDTH-1:0] b_value5;
    logic signed [DATA_WIDTH-1:0] b_value6;
    logic signed [DATA_WIDTH-1:0] b_value7;

    //==========================================================================
    // Metadata
    //==========================================================================

    logic [2:0] metadata0;
    logic [2:0] metadata1;

    //==========================================================================
    // Result / Metrics
    //==========================================================================

    logic signed [ACC_WIDTH-1:0] result;
    logic [15:0] mac_count;

    //==========================================================================
    // DUT
    //==========================================================================

    sparse_compute_controller #(
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),
        .K_SIZE     (K_SIZE)
    ) dut (

        .clk (clk),
        .rst (rst),

        .start (start),

        .busy (busy),
        .done (done),

        .sparse_a_value0 (sparse_a_value0),
        .sparse_a_value1 (sparse_a_value1),
        .sparse_a_value2 (sparse_a_value2),
        .sparse_a_value3 (sparse_a_value3),

        .b_value0 (b_value0),
        .b_value1 (b_value1),
        .b_value2 (b_value2),
        .b_value3 (b_value3),
        .b_value4 (b_value4),
        .b_value5 (b_value5),
        .b_value6 (b_value6),
        .b_value7 (b_value7),

        .metadata0 (metadata0),
        .metadata1 (metadata1),

        .result (result),

        .mac_count (mac_count)
    );

    //==========================================================================
    // Expected Result
    //==========================================================================

    logic signed [ACC_WIDTH-1:0] expected_result;

    integer errors;

    //==========================================================================
    // Helper: Start Operation
    //==========================================================================

    task automatic start_operation;
        begin

            @(negedge clk);

            start = 1'b1;

            @(negedge clk);

            start = 1'b0;

        end
    endtask

    //==========================================================================
    // Helper: Wait for Completion
    //==========================================================================

    task automatic wait_for_done;
        integer timeout;

        begin

            timeout = 0;

            while (!done) begin

                @(posedge clk);

                timeout = timeout + 1;

                if (timeout > 20) begin

                    $display("");
                    $display("ERROR: Timeout waiting for DUT completion");
                    errors = errors + 1;

                    disable wait_for_done;

                end

            end

        end
    endtask

    //==========================================================================
    // Main Test
    //==========================================================================

    initial begin

        //---------------------------------------------------------------------- 
        // Initial values
        //----------------------------------------------------------------------

        rst = 1'b1;
        start = 1'b0;

        sparse_a_value0 = '0;
        sparse_a_value1 = '0;
        sparse_a_value2 = '0;
        sparse_a_value3 = '0;

        b_value0 = '0;
        b_value1 = '0;
        b_value2 = '0;
        b_value3 = '0;
        b_value4 = '0;
        b_value5 = '0;
        b_value6 = '0;
        b_value7 = '0;

        metadata0 = 3'b000;
        metadata1 = 3'b000;

        expected_result = '0;

        errors = 0;

        //---------------------------------------------------------------------- 
        // Reset
        //----------------------------------------------------------------------

        repeat (3)
            @(posedge clk);

        rst = 1'b0;

        @(posedge clk);

        //======================================================================
        // TEST 1
        //
        // Dense equivalent:
        //
        // A = [10,20,0,0,30,0,0,40]
        //
        // B = [1,2,3,4,5,6,7,8]
        //
        // Metadata:
        //
        //   000 -> positions {0,1}
        //   010 -> positions {0,3}
        //
        // Therefore:
        //
        //   10*1 + 20*2 + 30*5 + 40*8
        //
        // = 520
        //
        //----------------------------------------------------------------------

        $display("");
        $display("==============================================");
        $display("SPARSE COMPUTE TEST 1");
        $display("==============================================");

        sparse_a_value0 = 32'sd10;
        sparse_a_value1 = 32'sd20;
        sparse_a_value2 = 32'sd30;
        sparse_a_value3 = 32'sd40;

        b_value0 = 32'sd1;
        b_value1 = 32'sd2;
        b_value2 = 32'sd3;
        b_value3 = 32'sd4;
        b_value4 = 32'sd5;
        b_value5 = 32'sd6;
        b_value6 = 32'sd7;
        b_value7 = 32'sd8;

        // 000 -> {0,1}
        metadata0 = 3'b000;

        // 010 -> {0,3}
        metadata1 = 3'b010;

        expected_result =
              (64'sd10 * 64'sd1)
            + (64'sd20 * 64'sd2)
            + (64'sd30 * 64'sd5)
            + (64'sd40 * 64'sd8);

        $display("Expected result : %0d", expected_result);
        $display("Expected MACs   : 4");

        //---------------------------------------------------------------------- 
        // Start
        //----------------------------------------------------------------------

        start_operation;

        //---------------------------------------------------------------------- 
        // Check busy
        //----------------------------------------------------------------------

        if (!busy) begin

            $display("FAIL: busy was not asserted");
            errors = errors + 1;

        end
        else begin

            $display("PASS: busy asserted");

        end

        //---------------------------------------------------------------------- 
        // Wait for completion
        //----------------------------------------------------------------------

        wait_for_done;

        //---------------------------------------------------------------------- 
        // Check result
        //----------------------------------------------------------------------

        if (result !== expected_result) begin

            $display(
                "FAIL: Result mismatch. Expected=%0d Got=%0d",
                expected_result,
                result
            );

            errors = errors + 1;

        end
        else begin

            $display(
                "PASS: Result = %0d",
                result
            );

        end

        //---------------------------------------------------------------------- 
        // Check MAC count
        //----------------------------------------------------------------------

        if (mac_count !== 16'd4) begin

            $display(
                "FAIL: MAC count mismatch. Expected=4 Got=%0d",
                mac_count
            );

            errors = errors + 1;

        end
        else begin

            $display("PASS: MAC count = 4");

        end

        //---------------------------------------------------------------------- 
        // Check done
        //----------------------------------------------------------------------

        if (!done) begin

            $display("FAIL: done was not asserted");
            errors = errors + 1;

        end
        else begin

            $display("PASS: done asserted");

        end

        //---------------------------------------------------------------------- 
        // Wait until controller returns to IDLE
        //----------------------------------------------------------------------

        @(posedge clk);

        if (busy) begin

            $display("FAIL: busy remained asserted after completion");
            errors = errors + 1;

        end
        else begin

            $display("PASS: busy deasserted after completion");

        end

        //======================================================================
        // TEST 2
        //
        // This test specifically checks that the previous accumulator value
        // does not leak into a new operation.
        //
        // A = [1,2,0,0,3,0,0,4]
        // B = [10,20,30,40,50,60,70,80]
        //
        // Metadata remains:
        //   000 -> {0,1}
        //   010 -> {0,3}
        //
        // Expected:
        //
        //   1*10 + 2*20 + 3*50 + 4*80
        //
        // = 490
        //
        //----------------------------------------------------------------------

        $display("");
        $display("==============================================");
        $display("SPARSE COMPUTE TEST 2");
        $display("ACCUMULATOR CLEAR CHECK");
        $display("==============================================");

        sparse_a_value0 = 32'sd1;
        sparse_a_value1 = 32'sd2;
        sparse_a_value2 = 32'sd3;
        sparse_a_value3 = 32'sd4;

        b_value0 = 32'sd10;
        b_value1 = 32'sd20;
        b_value2 = 32'sd30;
        b_value3 = 32'sd40;
        b_value4 = 32'sd50;
        b_value5 = 32'sd60;
        b_value6 = 32'sd70;
        b_value7 = 32'sd80;

        expected_result =
              (64'sd1 * 64'sd10)
            + (64'sd2 * 64'sd20)
            + (64'sd3 * 64'sd50)
            + (64'sd4 * 64'sd80);

        $display("Expected result : %0d", expected_result);
        $display("Expected MACs   : 4");

        start_operation;

        wait_for_done;

        //---------------------------------------------------------------------- 
        // Result check
        //----------------------------------------------------------------------

        if (result !== expected_result) begin

            $display(
                "FAIL: Result mismatch. Expected=%0d Got=%0d",
                expected_result,
                result
            );

            errors = errors + 1;

        end
        else begin

            $display(
                "PASS: Result = %0d",
                result
            );

        end

        //---------------------------------------------------------------------- 
        // MAC count check
        //----------------------------------------------------------------------

        if (mac_count !== 16'd4) begin

            $display(
                "FAIL: MAC count mismatch. Expected=4 Got=%0d",
                mac_count
            );

            errors = errors + 1;

        end
        else begin

            $display("PASS: MAC count = 4");

        end

        //======================================================================
        // Final Result
        //======================================================================

        $display("");
        $display("==============================================");

        if (errors == 0) begin

            $display("SPARSE COMPUTE CONTROLLER TEST PASSED");

        end
        else begin

            $display(
                "SPARSE COMPUTE CONTROLLER TEST FAILED: %0d errors",
                errors
            );

        end

        $display("==============================================");
        $display("");

        $finish;

    end

endmodule

`default_nettype wire