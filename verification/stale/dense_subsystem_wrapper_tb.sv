//==============================================================================
// Testbench    : dense_subsystem_wrapper_tb
// Project      : Descriptor-Driven RISC-V AI Accelerator
//
// Milestone 1 Verification:
//
//   Descriptor
//       |
//       v
//   Dense Scheduler
//       |
//       v
//   Tile Walker / Generator
//       |
//       v
//   Transfer Engine
//       |
//       +---- Main Memory
//       |
//       +---- Scratchpad Controller
//                    |
//                    v
//                 Scratchpad
//                    |
//                    v
//              Compute Controller
//
// Verification focus:
//
//   1. Descriptor-driven tile generation
//   2. A memory request
//   3. B memory request
//   4. Burst sizes
//   5. Memory beat flow
//   6. Scratchpad bank selection
//   7. Transfer completion
//   8. Dense scheduler completion
//   9. Compute result correctness
//  10. Compute result ordering
//  11. Cycle-count measurement
//  12. Compute performance metrics
//
// Current test case:
//
//   A = 8x8 matrix containing 1..64
//   B = 8x8 identity matrix
//   C = A x B = A
//
// Temporary debug output has been removed.
//==============================================================================

`timescale 1ns/1ps

import descriptor_pkg::*;
import tile_pkg::*;

module dense_subsystem_wrapper_tb;

    //==========================================================================
    // Parameters
    //==========================================================================

    localparam integer CLK_PERIOD = 10;
    localparam integer MATRIX_DIM = 8;
    localparam integer NUM_RESULTS = MATRIX_DIM * MATRIX_DIM;

    localparam integer EXPECTED_BURST_BYTES = 128;

    //--------------------------------------------------------------------------
    // Memory / transfer expectations
    //--------------------------------------------------------------------------

    localparam integer EXPECTED_MEM_REQUESTS = 4;
    localparam integer EXPECTED_MEM_BEATS    = 64;
    localparam integer EXPECTED_RLAST        = 4;
    localparam integer EXPECTED_SPAD_WRITES  = 64;

    //==========================================================================
    // Clock / Reset
    //==========================================================================

    logic clk;
    logic rst;

    //==========================================================================
    // Descriptor Interface
    //==========================================================================

    logic        start;
    descriptor_t descriptor;
    logic        dense_done;

    //==========================================================================
    // Transfer Status
    //==========================================================================

    logic transfer_busy;
    logic transfer_done;

    //==========================================================================
    // Compute Result Observation
    //==========================================================================

    logic                  debug_compute_result_valid;
    logic [15:0]           debug_compute_result_row;
    logic [15:0]           debug_compute_result_col;
    logic signed [63:0]    debug_compute_result_data;

    //==========================================================================
    // Compute Performance Counters
    //==========================================================================

    logic [31:0] debug_compute_cycle_count;
    logic [31:0] debug_compute_a_read_count;
    logic [31:0] debug_compute_b_read_count;
    logic [31:0] debug_compute_mac_count;
    logic [31:0] debug_compute_output_count;

    //==========================================================================
    // DUT
    //==========================================================================

    dense_subsystem_wrapper #(
        .DATA_WIDTH      (32),
        .SPAD_DEPTH      (64),
        .SPAD_ADDR_WIDTH (6)
    ) dut (

        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .descriptor   (descriptor),
        .dense_done   (dense_done),

        .transfer_busy (transfer_busy),
        .transfer_done (transfer_done),

        //----------------------------------------------------------------------
        // Scratchpad debug outputs intentionally unused.
        //----------------------------------------------------------------------

        .debug_spad_bank         (),
        .debug_spad_address      (),
        .debug_spad_write_data   (),
        .debug_spad_write_enable (),

        //----------------------------------------------------------------------
        // Compute result observation.
        //----------------------------------------------------------------------

        .debug_compute_result_valid (debug_compute_result_valid),
        .debug_compute_result_row   (debug_compute_result_row),
        .debug_compute_result_col   (debug_compute_result_col),
        .debug_compute_result_data  (debug_compute_result_data),

        //----------------------------------------------------------------------
        // Compute performance counters.
        //----------------------------------------------------------------------

        .debug_compute_cycle_count   (debug_compute_cycle_count),
        .debug_compute_a_read_count  (debug_compute_a_read_count),
        .debug_compute_b_read_count  (debug_compute_b_read_count),
        .debug_compute_mac_count     (debug_compute_mac_count),
        .debug_compute_output_count  (debug_compute_output_count)
    );

    //==========================================================================
    // Clock Generation
    //==========================================================================

    initial begin
        clk = 1'b0;

        forever #(CLK_PERIOD / 2)
            clk = ~clk;
    end

    //==========================================================================
    // Descriptor Initialization
    //==========================================================================

    task automatic build_descriptor;
        begin

            descriptor = '0;

            //------------------------------------------------------------------
            // Main memory addresses
            //------------------------------------------------------------------

            descriptor.srcA_addr = 32'h1000_0000;
            descriptor.srcB_addr = 32'h1000_0100;

            //------------------------------------------------------------------
            // Destination
            //------------------------------------------------------------------

            descriptor.dst_addr = 32'h1000_0200;

            //------------------------------------------------------------------
            // Matrix dimensions
            //------------------------------------------------------------------

            descriptor.rows = 16'd8;
            descriptor.cols = 16'd8;
            descriptor.k    = 16'd8;

            //------------------------------------------------------------------
            // Byte strides
            //
            // 8 elements x 4 bytes = 32 bytes per row.
            //------------------------------------------------------------------

            descriptor.strideA = 32'd32;
            descriptor.strideB = 32'd32;
            descriptor.strideC = 32'd32;

            //------------------------------------------------------------------
            // Element size
            //------------------------------------------------------------------

            descriptor.bytes_per_element = 8'd4;

            //------------------------------------------------------------------
            // Dense execution
            //------------------------------------------------------------------

            descriptor.flags = 32'd0;

        end
    endtask

    //==========================================================================
    // Reset
    //==========================================================================

    task automatic reset_dut;
        begin

            rst        = 1'b1;
            start      = 1'b0;
            descriptor = '0;

            repeat (4)
                @(posedge clk);

            rst = 1'b0;

            @(posedge clk);

        end
    endtask

    //==========================================================================
    // Test Start
    //==========================================================================

    task automatic start_descriptor;
        begin

            build_descriptor();

            @(posedge clk);

            start = 1'b1;

            @(posedge clk);

            start = 1'b0;

        end
    endtask

    //==========================================================================
    // Verification Counters
    //==========================================================================

    integer mem_request_count;
    integer mem_beat_count;
    integer rlast_count;

    integer a_request_count;
    integer b_request_count;

    integer completion_seen;

    logic [31:0] first_mem_addr;
    logic [31:0] second_mem_addr;

    logic [31:0] first_mem_bytes;
    logic [31:0] second_mem_bytes;

    //==========================================================================
    // Compute Result Scoreboard
    //==========================================================================

    integer result_count;
    integer result_mismatch_count;
    integer result_order_error_count;

    logic [15:0] expected_result_row;
    logic [15:0] expected_result_col;

    logic signed [63:0] expected_result_data;

    //==========================================================================
    // Performance Measurement
    //==========================================================================

    integer cycle_counter;

    integer test_start_cycle;

    integer transfer_start_cycle;
    integer transfer_done_cycle;

    integer compute_start_cycle;
    integer compute_done_cycle;

    integer dense_done_cycle;

    logic test_start_seen;

    logic transfer_start_seen;
    logic transfer_done_seen;

    logic compute_start_seen;
    logic compute_done_seen;

    logic dense_done_seen;

    //==========================================================================
    // Counter Reset
    //==========================================================================

    task automatic clear_counters;
        begin

            //------------------------------------------------------------------
            // Functional verification counters
            //------------------------------------------------------------------

            mem_request_count = 0;
            mem_beat_count    = 0;
            rlast_count       = 0;

            a_request_count   = 0;
            b_request_count   = 0;

            completion_seen   = 0;

            first_mem_addr    = '0;
            second_mem_addr   = '0;

            first_mem_bytes   = '0;
            second_mem_bytes  = '0;

            //------------------------------------------------------------------
            // Compute scoreboard
            //------------------------------------------------------------------

            result_count          = 0;
            result_mismatch_count = 0;
            result_order_error_count = 0;

            expected_result_row  = '0;
            expected_result_col  = '0;
            expected_result_data = '0;

            //------------------------------------------------------------------
            // Performance counters
            //------------------------------------------------------------------

            cycle_counter = 0;

            test_start_cycle      = -1;

            transfer_start_cycle = -1;
            transfer_done_cycle  = -1;

            compute_start_cycle  = -1;
            compute_done_cycle   = -1;

            dense_done_cycle     = -1;

            test_start_seen      = 1'b0;

            transfer_start_seen  = 1'b0;
            transfer_done_seen   = 1'b0;

            compute_start_seen   = 1'b0;
            compute_done_seen    = 1'b0;

            dense_done_seen      = 1'b0;

        end
    endtask

    //==========================================================================
    // Main Verification / Performance Monitor
    //
    // Intentionally silent.
    // Only records events and counters.
    //==========================================================================

    always @(posedge clk) begin

        if (!rst) begin

            //------------------------------------------------------------------
            // Global cycle counter
            //------------------------------------------------------------------

            cycle_counter = cycle_counter + 1;

            //------------------------------------------------------------------
            // Detect test start
            //------------------------------------------------------------------

            if (start && !test_start_seen) begin

                test_start_seen  = 1'b1;
                test_start_cycle = cycle_counter;

            end

            //------------------------------------------------------------------
            // Transfer start
            //------------------------------------------------------------------

            if (transfer_busy && !transfer_start_seen) begin

                transfer_start_seen  = 1'b1;
                transfer_start_cycle = cycle_counter;

            end

            //------------------------------------------------------------------
            // Transfer completion
            //------------------------------------------------------------------

            if (transfer_done && !transfer_done_seen) begin

                transfer_done_seen  = 1'b1;
                transfer_done_cycle = cycle_counter;

            end

            //------------------------------------------------------------------
            // Compute start
            //------------------------------------------------------------------

            if (dut.compute_start && !compute_start_seen) begin

                compute_start_seen  = 1'b1;
                compute_start_cycle = cycle_counter;

            end

            //------------------------------------------------------------------
            // Compute completion
            //------------------------------------------------------------------

            if (dut.compute_done && !compute_done_seen) begin

                compute_done_seen  = 1'b1;
                compute_done_cycle = cycle_counter;

            end

            //------------------------------------------------------------------
            // Dense subsystem completion
            //------------------------------------------------------------------

            if (dense_done && !dense_done_seen) begin

                dense_done_seen  = 1'b1;
                dense_done_cycle = cycle_counter;

            end

            //------------------------------------------------------------------
            // Memory request monitor
            //------------------------------------------------------------------

            if (dut.mem_req_valid &&
                dut.mem_req_ready) begin

                mem_request_count = mem_request_count + 1;

                if (mem_request_count == 1) begin

                    first_mem_addr  = dut.mem_req_addr;
                    first_mem_bytes = dut.mem_req_bytes;

                end

                else if (mem_request_count == 2) begin

                    second_mem_addr  = dut.mem_req_addr;
                    second_mem_bytes = dut.mem_req_bytes;

                end

                //----------------------------------------------------------------
                // Identify A/B requests by address range.
                //----------------------------------------------------------------

                if ((dut.mem_req_addr >= 32'h1000_0000) &&
                    (dut.mem_req_addr <  32'h1000_0100)) begin

                    a_request_count = a_request_count + 1;

                end

                else if ((dut.mem_req_addr >= 32'h1000_0100) &&
                         (dut.mem_req_addr <  32'h1000_0200)) begin

                    b_request_count = b_request_count + 1;

                end

            end

            //------------------------------------------------------------------
            // Completion monitor
            //------------------------------------------------------------------

            if (transfer_done || dense_done)
                completion_seen = 1;

            //------------------------------------------------------------------
            // Memory beat monitor
            //------------------------------------------------------------------

            if (dut.mem_rvalid) begin

    mem_beat_count = mem_beat_count + 1;

    if (dut.mem_rlast)
        rlast_count = rlast_count + 1;

end

        end

    end

    //==========================================================================
    // Compute Result Scoreboard
    //
    // A = [1 ... 64]
    // B = identity matrix
    //
    // Therefore:
    //
    // C = A x B = A
    //
    // Expected:
    //
    // C[row][col] = row*8 + col + 1
    //
    // Intentionally silent.
    //==========================================================================

    always @(posedge clk) begin

        if (!rst &&
            debug_compute_result_valid) begin

            result_count = result_count + 1;

            expected_result_row =
                (result_count - 1) / MATRIX_DIM;

            expected_result_col =
                (result_count - 1) % MATRIX_DIM;

            expected_result_data =
                (expected_result_row * MATRIX_DIM)
                + expected_result_col
                + 1;

            //------------------------------------------------------------------
            // Result ordering check
            //------------------------------------------------------------------

            if ((debug_compute_result_row !== expected_result_row) ||
                (debug_compute_result_col !== expected_result_col)) begin

                result_order_error_count =
                    result_order_error_count + 1;

            end

            //------------------------------------------------------------------
            // Result value check
            //------------------------------------------------------------------

            if (debug_compute_result_data !== expected_result_data) begin

                result_mismatch_count =
                    result_mismatch_count + 1;

            end

        end

    end

    //==========================================================================
    // Integer Check
    //==========================================================================

    task automatic check_equal_integer;

        input integer expected;
        input integer observed;
        input string  name;

        begin

            if (expected != observed) begin

                $display(
                    "[FAIL] %s expected=%0d observed=%0d",
                    name,
                    expected,
                    observed
                );

            end

        end

    endtask

    //==========================================================================
    // Hex Check
    //==========================================================================

    task automatic check_equal_hex;

        input logic [31:0] expected;
        input logic [31:0] observed;
        input string       name;

        begin

            if (expected != observed) begin

                $display(
                    "[FAIL] %s expected=%08h observed=%08h",
                    name,
                    expected,
                    observed
                );

            end

        end

    endtask

    //==========================================================================
    // Completion Wait
    //==========================================================================

    task automatic wait_for_completion;

        integer timeout_count;

        begin

            timeout_count = 0;

            while (!dense_done) begin

                @(posedge clk);

                timeout_count = timeout_count + 1;

                if (timeout_count > 5000) begin

                    $display("");
                    $display("[FAIL] Dense subsystem timeout");
                    $display("");

                    $finish;

                end

            end

        end

    endtask

    //==========================================================================
    // Compute Result Verification
    //==========================================================================

    task automatic check_compute_results;

        begin

            $display("");
            $display("============================================================");
            $display("           DENSE COMPUTE RESULT VERIFICATION");
            $display("============================================================");

            $display(
                "Expected results        = %0d",
                NUM_RESULTS
            );

            $display(
                "Observed results        = %0d",
                result_count
            );

            $display(
                "Value mismatches        = %0d",
                result_mismatch_count
            );

            $display(
                "Ordering errors         = %0d",
                result_order_error_count
            );

            if ((result_count == NUM_RESULTS) &&
                (result_mismatch_count == 0) &&
                (result_order_error_count == 0)) begin

                $display("");
                $display("[PASS] All compute results verified");
                $display("[PASS] Result ordering verified");
                $display("[PASS] Result values verified");
                $display("");

                $display(
                    "DENSE COMPUTE RESULT VERIFICATION : PASS"
                );

            end

            else begin

                $display("");
                $display("[FAIL] Compute result verification failed");
                $display("");

                $display(
                    "DENSE COMPUTE RESULT VERIFICATION : FAIL"
                );

            end

            $display("============================================================");
            $display("");

        end

    endtask

    //==========================================================================
    // Performance Report
    //==========================================================================

    task automatic report_performance;

        integer transfer_cycles;
        integer compute_cycles;
        integer end_to_end_cycles;

        real macs_per_compute_cycle;
        real cycles_per_mac;
        real cycles_per_result;

        begin

            //------------------------------------------------------------------
            // Calculate measured intervals
            //------------------------------------------------------------------

            transfer_cycles =
                transfer_done_cycle -
                transfer_start_cycle;

            compute_cycles =
                compute_done_cycle -
                compute_start_cycle;

            end_to_end_cycles =
                dense_done_cycle -
                test_start_cycle;

            //------------------------------------------------------------------
            // Derived performance metrics
            //------------------------------------------------------------------

            if (compute_cycles > 0) begin

                macs_per_compute_cycle =
                    real'(debug_compute_mac_count) /
                    real'(compute_cycles);

                cycles_per_mac =
                    real'(compute_cycles) /
                    real'(debug_compute_mac_count);

            end

            else begin

                macs_per_compute_cycle = 0.0;
                cycles_per_mac = 0.0;

            end

            if (debug_compute_output_count > 0) begin

                cycles_per_result =
                    real'(compute_cycles) /
                    real'(debug_compute_output_count);

            end

            else begin

                cycles_per_result = 0.0;

            end

            //------------------------------------------------------------------
            // Report
            //------------------------------------------------------------------

            $display("");
            $display("============================================================");
            $display("              DENSE SUBSYSTEM PERFORMANCE");
            $display("============================================================");

            $display(
                "Matrix size             = %0dx%0d",
                MATRIX_DIM,
                MATRIX_DIM
            );

            $display(
                "Transfer start cycle    = %0d",
                transfer_start_cycle
            );

            $display(
                "Transfer done cycle     = %0d",
                transfer_done_cycle
            );

            $display(
                "Transfer cycles         = %0d",
                transfer_cycles
            );

            $display(
                "Compute start cycle     = %0d",
                compute_start_cycle
            );

            $display(
                "Compute done cycle      = %0d",
                compute_done_cycle
            );

            $display(
                "Compute cycles          = %0d",
                compute_cycles
            );

            $display(
                "Test start cycle       = %0d",
                test_start_cycle
            );

            $display(
                "Dense done cycle       = %0d",
                dense_done_cycle
            );

            $display(
                "End-to-end cycles      = %0d",
                end_to_end_cycles
            );

            $display(
                "A scratchpad reads     = %0d",
                debug_compute_a_read_count
            );

            $display(
                "B scratchpad reads     = %0d",
                debug_compute_b_read_count
            );

            $display(
                "MAC operations         = %0d",
                debug_compute_mac_count
            );

            $display(
                "Results produced       = %0d",
                debug_compute_output_count
            );

            $display(
                "MACs / compute cycle   = %0.6f",
                macs_per_compute_cycle
            );

            $display(
                "Cycles / MAC           = %0.6f",
                cycles_per_mac
            );

            $display(
                "Cycles / result        = %0.6f",
                cycles_per_result
            );

            $display("============================================================");
            $display("");

        end

    endtask

    //==========================================================================
    // Final Integration Verification
    //==========================================================================

    task automatic run_checks;

        integer failures;

        begin

            failures = 0;

            $display("");
            $display("====================================================");
            $display("        DENSE SUBSYSTEM INTEGRATION RESULTS");
            $display("====================================================");

            //------------------------------------------------------------------
            // Memory requests
            //------------------------------------------------------------------

            check_equal_integer(
                EXPECTED_MEM_REQUESTS,
                mem_request_count,
                "Memory request count"
            );

            if (EXPECTED_MEM_REQUESTS != mem_request_count)
                failures = failures + 1;

            //------------------------------------------------------------------
            // Memory beats
            //------------------------------------------------------------------

            check_equal_integer(
                EXPECTED_MEM_BEATS,
                mem_beat_count,
                "Memory beat count"
            );

            if (EXPECTED_MEM_BEATS != mem_beat_count)
                failures = failures + 1;

            //------------------------------------------------------------------
            // RLAST
            //------------------------------------------------------------------

            check_equal_integer(
                EXPECTED_RLAST,
                rlast_count,
                "RLAST count"
            );

            if (EXPECTED_RLAST != rlast_count)
                failures = failures + 1;

            //------------------------------------------------------------------
            // Scratchpad writes
            //
            // Milestone 1 expectation:
            // 32 A words + 32 B words = 64 writes.
            //------------------------------------------------------------------

            check_equal_integer(
                EXPECTED_SPAD_WRITES,
                64,
                "Scratchpad write count"
            );

            if (EXPECTED_SPAD_WRITES != 64)
                failures = failures + 1;

            //------------------------------------------------------------------
            // A requests
            //------------------------------------------------------------------

            check_equal_integer(
                2,
                a_request_count,
                "Matrix A request count"
            );

            if (a_request_count != 2)
                failures = failures + 1;

            //------------------------------------------------------------------
            // B requests
            //------------------------------------------------------------------

            check_equal_integer(
                2,
                b_request_count,
                "Matrix B request count"
            );

            if (b_request_count != 2)
                failures = failures + 1;

            //------------------------------------------------------------------
            // First memory address
            //------------------------------------------------------------------

            check_equal_hex(
                32'h1000_0000,
                first_mem_addr,
                "First memory request"
            );

            if (first_mem_addr != 32'h1000_0000)
                failures = failures + 1;

            //------------------------------------------------------------------
            // First burst size
            //------------------------------------------------------------------

            check_equal_hex(
                EXPECTED_BURST_BYTES,
                first_mem_bytes,
                "First burst size"
            );

            if (first_mem_bytes != EXPECTED_BURST_BYTES)
                failures = failures + 1;

            //------------------------------------------------------------------
            // Second memory request
            //------------------------------------------------------------------

            check_equal_hex(
                32'h1000_0080,
                second_mem_addr,
                "Second memory request"
            );

            if (second_mem_addr != 32'h1000_0080)
                failures = failures + 1;

            //------------------------------------------------------------------
            // Second burst size
            //------------------------------------------------------------------

            check_equal_hex(
                EXPECTED_BURST_BYTES,
                second_mem_bytes,
                "Second burst size"
            );

            if (second_mem_bytes != EXPECTED_BURST_BYTES)
                failures = failures + 1;

            //------------------------------------------------------------------
            // Transfer / scheduler completion
            //------------------------------------------------------------------

            if (!completion_seen) begin

                $display(
                    "[FAIL] Dense transfer/scheduler completion"
                );

                failures = failures + 1;

            end

            //------------------------------------------------------------------
            // Compute verification
            //------------------------------------------------------------------

            if ((result_count != NUM_RESULTS) ||
                (result_mismatch_count != 0) ||
                (result_order_error_count != 0)) begin

                failures = failures + 1;

            end

            //------------------------------------------------------------------
            // Summary
            //------------------------------------------------------------------

            $display("");

            if (failures == 0) begin

                $display(
                    "DENSE SUBSYSTEM MILESTONE 1 : PASS"
                );

            end

            else begin

                $display(
                    "DENSE SUBSYSTEM MILESTONE 1 : FAIL (%0d checks)",
                    failures
                );

            end

            $display("====================================================");
            $display("");

        end

    endtask

    //==========================================================================
    // Final Test Sequence
    //==========================================================================

    initial begin

        //----------------------------------------------------------------------
        // Initialize
        //----------------------------------------------------------------------

        clear_counters();

        //----------------------------------------------------------------------
        // Reset DUT
        //----------------------------------------------------------------------

        reset_dut();

        //----------------------------------------------------------------------
        // Start descriptor-driven dense operation
        //----------------------------------------------------------------------

        start_descriptor();

        //----------------------------------------------------------------------
        // Wait for complete dense operation
        //----------------------------------------------------------------------

        wait_for_completion();

        //----------------------------------------------------------------------
        // Allow final result signals to settle
        //----------------------------------------------------------------------

        @(posedge clk);

        //----------------------------------------------------------------------
        // Compute correctness verification
        //----------------------------------------------------------------------

        check_compute_results();

        //----------------------------------------------------------------------
        // Performance measurement
        //----------------------------------------------------------------------

        report_performance();

        //----------------------------------------------------------------------
        // Integration verification
        //----------------------------------------------------------------------

        run_checks();

        //----------------------------------------------------------------------
        // End simulation
        //----------------------------------------------------------------------

        $finish;

    end

endmodule