//==============================================================================
//
// Testbench : sparse_datapath_8x8_wrapper_tb
// Project   : Descriptor-Driven RISC-V AI Accelerator
//
// Purpose:
//   Final functional + metrics verification of the 8x8 sparse 2:4 datapath.
//
// Verifies:
//   1. Sparse tile request handshake
//   2. Main-memory -> transfer engine
//   3. Transfer engine -> scratchpad
//   4. Scratchpad A/B/metadata storage
//   5. Sparse operand readout
//   6. 8x8 sparse compute
//   7. 2:4 metadata interpretation
//   8. 256 executed MACs
//   9. Complete 8x8 result matrix
//  10. Research metrics
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module sparse_datapath_8x8_wrapper_tb;

    //==========================================================================
    // Parameters
    //==========================================================================

    localparam integer CLK_PERIOD = 10;

    localparam integer A_ROWS  = 8;
    localparam integer A_COLS  = 4;

    localparam integer B_ROWS  = 8;
    localparam integer B_COLS  = 8;

    localparam integer META_COLS = 2;

    localparam integer TOTAL_A_WORDS    = 32;
    localparam integer TOTAL_B_WORDS    = 64;
    localparam integer TOTAL_META_WORDS = 16;

    localparam integer TOTAL_WORDS =
        TOTAL_A_WORDS +
        TOTAL_B_WORDS +
        TOTAL_META_WORDS;

    //==========================================================================
    // Clock / Reset
    //==========================================================================

    logic clk;
    logic rst;

    initial begin
        clk = 1'b0;
    end

    always #(CLK_PERIOD / 2) clk = ~clk;

    //==========================================================================
    // Sparse Tile Request
    //==========================================================================

    tile_pkg::sparse_tile_request_t sparse_tile_request;

    logic sparse_tile_request_valid;
    logic sparse_tile_request_ready;

    //==========================================================================
    // Main Memory Interface
    //==========================================================================

    logic        mem_req_valid;
    logic        mem_req_ready;
    logic [31:0] mem_req_addr;
    logic [31:0] mem_req_bytes;

    logic        mem_rvalid;
    logic [63:0] mem_rdata;
    logic        mem_rlast;

    //==========================================================================
    // Compute Interface
    //==========================================================================

    logic compute_start;
    logic compute_busy;
    logic compute_done;

    logic signed [63:0] compute_result [0:7][0:7];

    logic [31:0] compute_mac_count;

    //==========================================================================
    // Status
    //==========================================================================

    logic transfer_busy;
    logic transfer_done;

    logic datapath_busy;
    logic datapath_done;

    //==========================================================================
    // DUT
    //==========================================================================

    sparse_datapath_8x8_wrapper dut (
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

        .mem_req_valid(
            mem_req_valid
        ),

        .mem_req_ready(
            mem_req_ready
        ),

        .mem_req_addr(
            mem_req_addr
        ),

        .mem_req_bytes(
            mem_req_bytes
        ),

        .mem_rvalid(
            mem_rvalid
        ),

        .mem_rdata(
            mem_rdata
        ),

        .mem_rlast(
            mem_rlast
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

    //==========================================================================
    // Test Data
    //==========================================================================

    logic signed [31:0] A [0:7][0:3];
    logic signed [31:0] B [0:7][0:7];

    logic [2:0] META [0:7][0:1];

    logic signed [63:0] EXPECTED_C [0:7][0:7];

    //==========================================================================
    // Main Memory Image
    //
    // Word layout:
    //
    //   words   0..31   -> compressed A
    //   words  32..95   -> dense B
    //   words  96..111  -> metadata
    //
    // Each memory response beat contains two 32-bit words.
    //==========================================================================

    logic [31:0] memory_image [0:TOTAL_WORDS-1];

    //==========================================================================
    // Memory Driver State
    //==========================================================================

    integer memory_word_index;
    integer memory_beat_index;

    logic memory_sending;

    logic [31:0] memory_request_bytes;

    //==========================================================================
    // Verification Counters
    //==========================================================================

    integer errors;

    integer mem_request_count;
    integer mem_response_count;

    //==========================================================================
    // Research Metrics
    //==========================================================================

    integer sim_cycle;

    integer transfer_start_cycle;
    integer transfer_done_cycle;

    integer operand_read_start_cycle;
    integer compute_busy_start_cycle;
    integer compute_done_cycle;


    integer transfer_cycles;
    integer operand_read_cycles;
    integer compute_cycles;
    integer end_to_end_cycles;

    integer memory_beat_count;
    integer memory_bytes_transferred;

    integer compute_wait_cycles;

    //==========================================================================
    // Test Data Initialization
    //==========================================================================

    task automatic initialize_test_data;

        integer r;
        integer c;
        integer idx;

        begin

            //------------------------------------------------------------------
            // Compressed A
            //------------------------------------------------------------------

            A[0][0] = 10;
            A[0][1] = 20;
            A[0][2] = 30;
            A[0][3] = 40;

            A[1][0] = 50;
            A[1][1] = 60;
            A[1][2] = 70;
            A[1][3] = 80;

            A[2][0] = 90;
            A[2][1] = 11;
            A[2][2] = 12;
            A[2][3] = 13;

            A[3][0] = 14;
            A[3][1] = 15;
            A[3][2] = 16;
            A[3][3] = 17;

            A[4][0] = 18;
            A[4][1] = 19;
            A[4][2] = 20;
            A[4][3] = 21;

            A[5][0] = 22;
            A[5][1] = 23;
            A[5][2] = 24;
            A[5][3] = 25;

            A[6][0] = 26;
            A[6][1] = 27;
            A[6][2] = 28;
            A[6][3] = 29;

            A[7][0] = 31;
            A[7][1] = 32;
            A[7][2] = 33;
            A[7][3] = 34;

            //------------------------------------------------------------------
            // Dense B
            //------------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 1) begin
                    B[r][c] = (r * 8) + c + 1;
                end
            end

            //------------------------------------------------------------------
            // 2:4 Metadata
            //------------------------------------------------------------------

            META[0][0] = 3'b010;
            META[0][1] = 3'b001;

            META[1][0] = 3'b011;
            META[1][1] = 3'b100;

            META[2][0] = 3'b010;
            META[2][1] = 3'b000;

            META[3][0] = 3'b011;
            META[3][1] = 3'b001;

            META[4][0] = 3'b001;
            META[4][1] = 3'b100;

            META[5][0] = 3'b011;
            META[5][1] = 3'b000;

            META[6][0] = 3'b000;
            META[6][1] = 3'b011;

            META[7][0] = 3'b011;
            META[7][1] = 3'b010;

            //------------------------------------------------------------------
            // Clear memory image
            //------------------------------------------------------------------

            for (idx = 0; idx < TOTAL_WORDS; idx = idx + 1)
                memory_image[idx] = 32'd0;

            //------------------------------------------------------------------
            // Pack compressed A
            //------------------------------------------------------------------

            idx = 0;

            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    memory_image[idx] = A[r][c];
                    idx = idx + 1;
                end
            end

            //------------------------------------------------------------------
            // Pack B
            //------------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 1) begin
                    memory_image[idx] = B[r][c];
                    idx = idx + 1;
                end
            end

            //------------------------------------------------------------------
            // Pack metadata
            //------------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 2; c = c + 1) begin
                    memory_image[idx] = {
                        29'd0,
                        META[r][c]
                    };

                    idx = idx + 1;
                end
            end

        end

    endtask

    //==========================================================================
    // Expected C Matrix
    //==========================================================================

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

        //==========================================================================
    // Global Simulation Cycle Counter
    //==========================================================================

    always @(posedge clk) begin
        if (rst)
            sim_cycle <= 0;
        else
            sim_cycle <= sim_cycle + 1;
    end

 

    //==========================================================================
    // Main Memory Model
    //
    // One 64-bit response beat contains two 32-bit words.
    //==========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            mem_req_ready        <= 1'b0;
            mem_rvalid           <= 1'b0;
            mem_rdata            <= 64'd0;
            mem_rlast            <= 1'b0;

            memory_sending       <= 1'b0;
            memory_word_index    <= 0;
            memory_beat_index    <= 0;
            memory_request_bytes <= 32'd0;

        end

        else begin

            //--------------------------------------------------------------
            // Memory request channel always ready.
            //--------------------------------------------------------------

            mem_req_ready <= 1'b1;

            //--------------------------------------------------------------
            // Default response values.
            //--------------------------------------------------------------

            mem_rvalid <= 1'b0;
            mem_rlast  <= 1'b0;

            //--------------------------------------------------------------
            // Accept request.
            //--------------------------------------------------------------

            if (mem_req_valid &&
                mem_req_ready &&
                !memory_sending) begin

                memory_sending       <= 1'b1;
                memory_word_index    <= mem_req_addr / 4;
                memory_beat_index    <= 0;
                memory_request_bytes <= mem_req_bytes;

                mem_request_count =
                    mem_request_count + 1;

                memory_beat_count =
                    memory_beat_count +
                    (mem_req_bytes / 8);

                memory_bytes_transferred =
                    memory_bytes_transferred +
                    mem_req_bytes;

                $display(
                    "[MEM_REQ] t=%0t addr=%08h bytes=%0d beats=%0d",
                    $time,
                    mem_req_addr,
                    mem_req_bytes,
                    mem_req_bytes / 8
                );

            end

            //--------------------------------------------------------------
            // Return response beats.
            //--------------------------------------------------------------

            if (memory_sending) begin

                mem_rvalid <= 1'b1;

                mem_rdata <= {
                    memory_image[memory_word_index + 1],
                    memory_image[memory_word_index]
                };

                mem_response_count =
                    mem_response_count + 1;

                //----------------------------------------------------------
                // Last beat.
                //----------------------------------------------------------

                if (memory_beat_index ==
                    (memory_request_bytes / 8) - 1) begin

                    mem_rlast <= 1'b1;

                    memory_sending <= 1'b0;

                end

                else begin

                    memory_word_index <=
                        memory_word_index + 2;

                    memory_beat_index <=
                        memory_beat_index + 1;

                end

            end

        end

    end

    //==========================================================================
    // Sparse Request Driver
    //
    // IMPORTANT:
    // VALID is asserted on a falling edge and held through the rising edge.
    // This avoids the clock-edge race we encountered earlier.
    //==========================================================================

    task automatic submit_sparse_request;

        begin

            @(negedge clk);

            sparse_tile_request_valid = 1'b1;

            while (!sparse_tile_request_ready)
                @(negedge clk);

            @(posedge clk);

            $display(
                "[REQTB] Handshake at t=%0t VALID=%b READY=%b",
                $time,
                sparse_tile_request_valid,
                sparse_tile_request_ready
            );

            @(negedge clk);

            sparse_tile_request_valid = 1'b0;

            $display("[PASS] Sparse request accepted");

        end

    endtask

    //==========================================================================
    // Operand Verification
    //==========================================================================

    task automatic verify_captured_operands;

        integer r;
        integer c;

        begin

            $display("");
            $display("----------------------------------------------");
            $display("OPERAND VERIFICATION");
            $display("----------------------------------------------");

            //--------------------------------------------------------------
            // A
            //--------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 4; c = c + 1) begin

                    if (^dut.sparse_a[r][c] === 1'bx) begin

                        $display(
                            "[FAIL] A[%0d][%0d] = X/Z",
                            r,
                            c
                        );

                        errors = errors + 1;

                    end

                    else if (dut.sparse_a[r][c] !== A[r][c]) begin

                        $display(
                            "[FAIL] A[%0d][%0d] expected %0d got %0d",
                            r,
                            c,
                            A[r][c],
                            dut.sparse_a[r][c]
                        );

                        errors = errors + 1;

                    end

                end

            end

            //--------------------------------------------------------------
            // B
            //--------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 8; c = c + 1) begin

                    if (^dut.dense_b[r][c] === 1'bx) begin

                        $display(
                            "[FAIL] B[%0d][%0d] = X/Z",
                            r,
                            c
                        );

                        errors = errors + 1;

                    end

                    else if (dut.dense_b[r][c] !== B[r][c]) begin

                        $display(
                            "[FAIL] B[%0d][%0d] expected %0d got %0d",
                            r,
                            c,
                            B[r][c],
                            dut.dense_b[r][c]
                        );

                        errors = errors + 1;

                    end

                end

            end

            //--------------------------------------------------------------
            // Metadata
            //--------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 2; c = c + 1) begin

                    if (^dut.sparse_metadata[r][c] === 1'bx) begin

                        $display(
                            "[FAIL] META[%0d][%0d] = X/Z",
                            r,
                            c
                        );

                        errors = errors + 1;

                    end

                    else if (
                        dut.sparse_metadata[r][c] !== META[r][c]
                    ) begin

                        $display(
                            "[FAIL] META[%0d][%0d] expected %03b got %03b",
                            r,
                            c,
                            META[r][c],
                            dut.sparse_metadata[r][c]
                        );

                        errors = errors + 1;

                    end

                end

            end

            if (errors == 0)
                $display("[PASS] All captured operands match");

        end

    endtask

    //==========================================================================
    // Result Verification
    //==========================================================================

    task automatic verify_results;

        integer r;
        integer c;

        begin

            $display("");
            $display("----------------------------------------------");
            $display("SPARSE 8x8 RESULT");
            $display("----------------------------------------------");

            //--------------------------------------------------------------
            // Print complete result matrix.
            //--------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin

                $display(
                    "C[%0d] = [%0d, %0d, %0d, %0d, %0d, %0d, %0d, %0d]",
                    r,
                    compute_result[r][0],
                    compute_result[r][1],
                    compute_result[r][2],
                    compute_result[r][3],
                    compute_result[r][4],
                    compute_result[r][5],
                    compute_result[r][6],
                    compute_result[r][7]
                );

            end

            //--------------------------------------------------------------
            // Compare all 64 results.
            //--------------------------------------------------------------

            $display("");
            $display("----------------------------------------------");
            $display("RESULT VERIFICATION");
            $display("----------------------------------------------");

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 8; c = c + 1) begin

                    if (^compute_result[r][c] === 1'bx) begin

                        $display(
                            "[FAIL] C[%0d][%0d] = X/Z",
                            r,
                            c
                        );

                        errors = errors + 1;

                    end

                    else if (
                        compute_result[r][c] !== EXPECTED_C[r][c]
                    ) begin

                        $display(
                            "[FAIL] C[%0d][%0d] expected %0d got %0d",
                            r,
                            c,
                            EXPECTED_C[r][c],
                            compute_result[r][c]
                        );

                        errors = errors + 1;

                    end

                end

            end

            if (errors == 0)
                $display("[PASS] All 64 output elements match");
            else
                $display(
                    "[FAIL] Result verification has %0d errors",
                    errors
                );

        end

    endtask

        //==========================================================================
    // Main Test
    //==========================================================================

    initial begin

        //======================================================================
        // Initial conditions
        //======================================================================

        errors = 0;

        mem_request_count = 0;
        mem_response_count = 0;

        memory_beat_count = 0;
        memory_bytes_transferred = 0;

        sim_cycle = 0;

        transfer_start_cycle = 0;
        transfer_done_cycle = 0;

        operand_read_start_cycle = 0;
        compute_busy_start_cycle = 0;
        compute_done_cycle = 0;


        transfer_cycles = 0;
        operand_read_cycles = 0;
        compute_cycles = 0;
        end_to_end_cycles = 0;

        compute_wait_cycles = 0;

        sparse_tile_request = '0;
        sparse_tile_request_valid = 1'b0;

        compute_start = 1'b0;

        //======================================================================
        // Initialize test data
        //======================================================================

        initialize_test_data();
        initialize_expected();

        //======================================================================
        // Header
        //======================================================================

        $display("");
        $display("====================================================");
        $display("SPARSE 8x8 FINAL FUNCTIONAL + METRICS TEST");
        $display("====================================================");

        //======================================================================
        // Reset
        //======================================================================

        rst = 1'b1;

        repeat (5)
            @(posedge clk);

        rst = 1'b0;

        repeat (2)
            @(posedge clk);

        //======================================================================
        // Build sparse tile request
        //======================================================================

        sparse_tile_request = '0;

        sparse_tile_request.valid     = 1'b1;
        sparse_tile_request.last_tile = 1'b1;

        sparse_tile_request.tile_context.tile_row = 16'd0;
        sparse_tile_request.tile_context.tile_col = 16'd0;
        sparse_tile_request.tile_context.tile_k   = 16'd0;

        //----------------------------------------------------------------------
        // Main-memory layout
        //
        // A:
        //   0x00000000
        //   128 bytes
        //
        // B:
        //   0x00000080
        //   256 bytes
        //
        // Metadata:
        //   0x00000180
        //   64 bytes
        //----------------------------------------------------------------------

        sparse_tile_request.values_addr_a =
            32'd0;

        sparse_tile_request.values_addr_b =
            32'd128;

        sparse_tile_request.metadata_addr_a =
            32'd384;

        sparse_tile_request.addr_c =
            32'd448;

        //----------------------------------------------------------------------
        // Dimensions
        //----------------------------------------------------------------------

        sparse_tile_request.rows   = 16'd8;
        sparse_tile_request.cols   = 16'd8;
        sparse_tile_request.k_size = 16'd8;

        //----------------------------------------------------------------------
        // Strides
        //----------------------------------------------------------------------

        sparse_tile_request.stride_a = 16'd4;
        sparse_tile_request.stride_b = 16'd8;

        //----------------------------------------------------------------------
        // Scratchpad banks
        //----------------------------------------------------------------------

        sparse_tile_request.bank_a =
            4'd0;

        sparse_tile_request.bank_b =
            4'd1;

        sparse_tile_request.metadata_bank =
            4'd2;

        sparse_tile_request.bank_c =
            4'd3;

        //----------------------------------------------------------------------
        // Transfer sizes
        //----------------------------------------------------------------------

        sparse_tile_request.transfer_bytes_a =
            32'd128;

        sparse_tile_request.transfer_bytes_b =
            32'd256;

        sparse_tile_request.metadata_transfer_bytes =
            32'd64;

        //======================================================================
        // Submit request
        //======================================================================

        $display("");
        $display("----------------------------------------------");
        $display("Submitting Sparse Tile Request");
        $display("----------------------------------------------");

        $display(
            "[REQ] A    addr=%08h bytes=%0d",
            sparse_tile_request.values_addr_a,
            sparse_tile_request.transfer_bytes_a
        );

        $display(
            "[REQ] B    addr=%08h bytes=%0d",
            sparse_tile_request.values_addr_b,
            sparse_tile_request.transfer_bytes_b
        );

        $display(
            "[REQ] META addr=%08h bytes=%0d",
            sparse_tile_request.metadata_addr_a,
            sparse_tile_request.metadata_transfer_bytes
        );

        //======================================================================
        // Transfer timing starts immediately before request.
        //======================================================================

        transfer_start_cycle = sim_cycle;

        submit_sparse_request();

        //======================================================================
        // Wait for transfer
        //======================================================================

        $display("");
        $display("----------------------------------------------");
        $display("Waiting for A/B/Metadata Transfer");
        $display("----------------------------------------------");

        wait (transfer_busy === 1'b1);

        $display(
            "[PASS] Transfer busy asserted at cycle %0d",
            sim_cycle
        );

        //======================================================================
        // Wait for transfer completion
        //======================================================================

        wait (transfer_done === 1'b1);

        transfer_done_cycle = sim_cycle;

        transfer_cycles =
            transfer_done_cycle -
            transfer_start_cycle;

        $display(
            "[PASS] Transfer completed in %0d cycles",
            transfer_cycles
        );

        //======================================================================
        // Basic transfer checks
        //======================================================================

        if (mem_request_count == 4) begin
            $display(
                "[PASS] Memory request count = %0d",
                mem_request_count
            );
        end
        else begin
            $display(
                "[FAIL] Memory request count expected 4 got %0d",
                mem_request_count
            );

            errors = errors + 1;
        end

        if (mem_response_count == 56) begin
            $display(
                "[PASS] Memory response beats = %0d",
                mem_response_count
            );
        end
        else begin
            $display(
                "[FAIL] Memory response beats expected 56 got %0d",
                mem_response_count
            );

            errors = errors + 1;
        end

        //======================================================================
// Start sparse operand read
//
// IMPORTANT:
// The wrapper requires:
//
//     compute_start == 1
//     transfer_complete_latched == 1
//
// on the SAME rising clock edge.
//
// Drive compute_start from the falling edge so it is stable before
// the wrapper samples it.
//======================================================================

@(negedge clk);

operand_read_start_cycle = sim_cycle;

compute_start = 1'b1;

$display(
    "[DBG] compute_start ASSERTED at cycle %0d",
    sim_cycle
);

$display(
    "[DBG] pre-sample: read_state=%0d transfer_latched=%b",
    dut.read_state,
    dut.transfer_complete_latched
);

//------------------------------------------------------------------
// Hold compute_start through the sampling edge.
//------------------------------------------------------------------

@(posedge clk);

$display(
    "[DBG] compute_start SAMPLE: read_state=%0d transfer_latched=%b",
    dut.read_state,
    dut.transfer_complete_latched
);

//------------------------------------------------------------------
// Keep it high for one additional cycle.
//
// This is intentional. It gives the wrapper a second opportunity
// to observe the request if the transfer completion latch becomes
// visible one cycle later.
//------------------------------------------------------------------

@(negedge clk);

if (dut.read_state == 0) begin

    $display(
        "[DBG] READ FSM still IDLE; holding compute_start"
    );

    compute_start = 1'b1;

end
else begin

    compute_start = 1'b0;

    $display(
        "[DBG] READ FSM accepted request; deasserting compute_start"
    );

end

@(posedge clk);

$display(
    "[DBG] post-start: read_state=%0d transfer_latched=%b",
    dut.read_state,
    dut.transfer_complete_latched
);

@(negedge clk);

compute_start = 1'b0;

$display(
    "[DBG] compute_start DEASSERTED at cycle %0d",
    sim_cycle
);

        //======================================================================
        // Wait for actual compute_busy
        //
        // This is the boundary between wrapper operand-read overhead and
        // actual sparse compute.
        //======================================================================
        $display(
    "[DBG] Before compute wait: read_state=%0d transfer_latched=%b sparse_compute_start=%b",
    dut.read_state,
    dut.transfer_complete_latched,
    dut.sparse_compute_start
);
        compute_wait_cycles = 0;

        while ((compute_busy !== 1'b1) &&
               (compute_wait_cycles < 1000)) begin

            @(posedge clk);

            compute_wait_cycles =
                compute_wait_cycles + 1;

        end

        if (compute_busy !== 1'b1) begin

            $display("");
            $display("==============================================");
            $display("[FAIL] Timeout waiting for compute_busy");
            $display("==============================================");

            $display(
                "[DBG] waited %0d cycles",
                compute_wait_cycles
            );

            $display(
                "[DBG] wrapper read_state = %0d",
                dut.read_state
            );

            errors = errors + 1;

        end
        else begin

            compute_busy_start_cycle = sim_cycle;

            operand_read_cycles =
                compute_busy_start_cycle -
                operand_read_start_cycle;

            $display(
                "[PASS] Sparse compute busy asserted"
            );

            $display(
                "[METRIC] Operand-read cycles = %0d",
                operand_read_cycles
            );

            //==================================================================
            // Now that the wrapper has completed operand capture, verify it.
            //==================================================================

            verify_captured_operands();

        end

        //======================================================================
// Wait for compute completion
//
// compute_done is a one-cycle pulse.
// Capture it directly here rather than using a separate monitor.
//======================================================================

if (compute_busy === 1'b1) begin

    compute_wait_cycles = 0;

    while ((compute_done !== 1'b1) &&
           (compute_wait_cycles < 2000)) begin

        @(posedge clk);

        compute_wait_cycles =
            compute_wait_cycles + 1;
    end

    if (compute_done !== 1'b1) begin

        $display("");
        $display("==============================================");
        $display("[FAIL] Timeout waiting for compute_done");
        $display("==============================================");

        $display(
            "[DBG] compute wait cycles = %0d",
            compute_wait_cycles
        );

        $display(
            "[DBG] wrapper read_state = %0d",
            dut.read_state
        );

        errors = errors + 1;

    end
    else begin

        compute_done_cycle = sim_cycle;

        compute_cycles =
            compute_done_cycle -
            compute_busy_start_cycle;

        $display(
            "[PASS] Sparse compute completed"
        );

        $display(
            "[METRIC] Sparse compute cycles = %0d",
            compute_cycles
        );

    end

end
else begin

    $display(
        "[FAIL] compute_busy was not asserted"
    );

    errors = errors + 1;

end

        //======================================================================
        // Give result one settling cycle
        //======================================================================

        @(posedge clk);

        //======================================================================
        // Compute status checks
        //======================================================================

        $display("");
        $display("----------------------------------------------");
        $display("COMPUTE STATUS");
        $display("----------------------------------------------");

       if (compute_done_cycle > 0) begin
    $display(
        "[PASS] compute_done pulse observed at cycle %0d",
        compute_done_cycle
    );
end
else begin
    $display(
        "[FAIL] compute_done pulse was not observed"
    );
    errors = errors + 1;
end

        if (compute_busy === 1'b0) begin
            $display("[PASS] compute_busy deasserted");
        end
        else begin
            $display("[FAIL] compute_busy still asserted");
            errors = errors + 1;
        end

        //======================================================================
        // MAC count
        //======================================================================

        if (compute_mac_count == 256) begin

            $display(
                "[PASS] Executed MAC count = %0d",
                compute_mac_count
            );

        end
        else begin

            $display(
                "[FAIL] Expected 256 MACs, got %0d",
                compute_mac_count
            );

            errors = errors + 1;

        end

        //======================================================================
        // Result verification
        //======================================================================

        verify_results();

        //======================================================================
        // End-to-end timing
        //======================================================================

        end_to_end_cycles =
            compute_done_cycle -
            transfer_start_cycle;

        //======================================================================
        // Final Research Metrics
        //
        // For the 8x8 matrix:
        //
        // Dense MAC opportunities = 8 * 8 * 8 = 512
        // Sparse 2:4 MACs         = 8 * 8 * 4 = 256
        //
        // External traffic:
        //
        // A       = 128 B
        // B       = 256 B
        // Metadata = 64 B
        //
        // Total sparse traffic = 448 B
        //======================================================================

        $display("");
        $display("====================================================");
        $display("          SPARSE 8x8 RESEARCH METRICS");
        $display("====================================================");

        $display("");
        $display("---- Workload ----");

        $display(
            "Matrix                         : 8 x 8"
        );

        $display(
            "Structured sparsity            : 2:4"
        );

        $display(
            "Sparsity                       : 50%%"
        );

        $display(
            "Dense MAC opportunities        : 512"
        );

        $display(
            "Sparse executed MACs           : %0d",
            compute_mac_count
        );

        $display(
            "MAC reduction                  : %0.2f%%",
            (1.0 -
             (compute_mac_count / 512.0)) * 100.0
        );

        $display("");
        $display("---- External Memory ----");

        $display(
            "Memory requests                : %0d",
            mem_request_count
        );

        $display(
            "Memory response beats          : %0d",
            memory_beat_count
        );

        $display(
            "External bytes transferred     : %0d B",
            memory_bytes_transferred
        );

        $display(
            "External traffic reduction     : %0.2f%%",
            (1.0 -
             (memory_bytes_transferred / 512.0)) * 100.0
        );

        $display("");
        $display("---- Timing ----");

        $display(
            "Transfer cycles                : %0d",
            transfer_cycles
        );

        $display(
            "Operand-read cycles            : %0d",
            operand_read_cycles
        );

        $display(
            "Sparse compute cycles          : %0d",
            compute_cycles
        );

        $display(
            "End-to-end cycles              : %0d",
            end_to_end_cycles
        );

        $display("");
        $display("---- Compute Efficiency ----");

        if (compute_cycles > 0) begin

    $display(
        "MACs / compute cycle           : %0.6f",
        compute_mac_count * 1.0 /
        compute_cycles
    );

    $display(
        "Cycles / MAC                   : %0.6f",
        compute_cycles * 1.0 /
        compute_mac_count
    );

end
        else begin

            $display(
                "MACs / compute cycle           : N/A"
            );

            $display(
                "Cycles / MAC                   : N/A"
            );

        end

        $display(
            "Cycles / output result         : %0.6f",
            end_to_end_cycles / 64.0
        );

        $display("");
        $display("---- Verification ----");

        $display(
            "Verification errors            : %0d",
            errors
        );

        //======================================================================
        // Final state
        //======================================================================

        $display("");
        $display("====================================================");
        $display("FINAL STATUS");
        $display("====================================================");

        if (errors == 0) begin

            $display(
                "SPARSE 8x8 FUNCTIONAL + METRICS TEST: PASS"
            );

        end
        else begin

            $display(
                "SPARSE 8x8 FUNCTIONAL + METRICS TEST: FAIL"
            );

        end

        $display("====================================================");

        $finish;

    end

endmodule

`default_nettype wire