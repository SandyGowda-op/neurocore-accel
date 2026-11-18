//==============================================================================
//
// Testbench    : sparse_datapath_8x8_research_tb
// Project      : Descriptor-Driven RISC-V AI Accelerator
//
// Purpose:
//   Research-measurement version of the already-verified 8x8 sparse datapath
//   testbench.
//
// IMPORTANT:
//   The functional stimulus, memory image, request handshake, operand
//   verification, and expected C matrix are preserved from the verified
//   sparse datapath TB. Only research counters/reporting are added.
//
// Research metrics collected:
//   - Functional result count / mismatches
//   - 2:4 sparsity and MAC reduction
//   - External memory requests / beats / RLAST / bytes
//   - Transfer cycles
//   - Scratchpad A/B/metadata read counts
//   - Scratchpad bytes read / bandwidth
//   - Operand-read latency
//   - Sparse compute cycles
//   - End-to-end cycles
//   - MACs/cycle
//   - Cycles/MAC
//   - MAC utilisation
//   - Non-MAC cycles / percentage
//   - Results/cycle
//   - Cycles/result
//
// Current sparse compute controller contains ONE MAC unit.
// Therefore theoretical peak = 1 MAC/cycle.
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module sparse_datapath_8x8_research_tb;

    //==========================================================================
    // Parameters
    //==========================================================================

    localparam integer CLK_PERIOD = 10;

    localparam integer MATRIX_DIM = 8;
    localparam integer A_ROWS = 8;
    localparam integer A_COMPRESSED_COLS = 4;
    localparam integer B_ROWS = 8;
    localparam integer B_COLS = 8;
    localparam integer META_COLS = 2;

    localparam integer TOTAL_A_WORDS = 32;
    localparam integer TOTAL_B_WORDS = 64;
    localparam integer TOTAL_META_WORDS = 16;

    localparam integer TOTAL_WORDS =
        TOTAL_A_WORDS +
        TOTAL_B_WORDS +
        TOTAL_META_WORDS;

    localparam integer TOTAL_BEATS = TOTAL_WORDS / 2;

    localparam integer ELEMENT_BYTES = 4;

    localparam integer DENSE_MAC_OPPORTUNITIES =
        MATRIX_DIM * MATRIX_DIM * MATRIX_DIM;

    localparam integer SPARSE_EXPECTED_MACS =
        MATRIX_DIM * MATRIX_DIM * A_COMPRESSED_COLS;

    localparam integer EXPECTED_RESULTS =
        MATRIX_DIM * MATRIX_DIM;

    // Dense reference traffic from the verified dense 8x8 baseline.
    localparam integer DENSE_EXTERNAL_BYTES = 512;

    //==========================================================================
    // Clock / Reset
    //==========================================================================

    logic clk;
    logic rst;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    //==========================================================================
    // Sparse Tile Request
    //==========================================================================

    import tile_pkg::*;

    sparse_tile_request_t sparse_tile_request;

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
    //   words   0..31   -> compressed A
    //   words  32..95   -> dense B
    //   words  96..111  -> metadata
    //
    // One response beat contains two 32-bit words.
    //==========================================================================

    logic [31:0] memory_image [0:TOTAL_WORDS-1];

    integer memory_word_index;
    integer memory_beat_index;
    integer memory_request_bytes;
    logic   memory_sending;

    //==========================================================================
    // Verification Counters
    //==========================================================================

    integer errors;

    integer mem_request_count;
    integer mem_response_count;
    integer rlast_count;

    integer result_count;
    integer result_mismatch_count;

    //==========================================================================
    // Research Timing Counters
    //==========================================================================

    integer cycle_counter;

    integer test_start_cycle;

    integer transfer_start_cycle;
    integer transfer_done_cycle;

    integer compute_start_cycle;
    integer sparse_compute_start_cycle;
    integer compute_busy_start_cycle;
    integer compute_wait_cycles;
    integer compute_done_cycle;

    integer transfer_cycles;
    integer operand_read_cycles;
    integer compute_cycles;
    integer end_to_end_cycles;

    integer a_read_count;
    integer b_read_count;
    integer metadata_read_count;

    integer external_bytes_transferred;

    //==========================================================================
    // Derived Research Metrics
    //==========================================================================

    integer total_spad_reads;
    integer spad_bytes_read;

    integer zero_mac_avoided;
    integer non_mac_cycles;

    real sparsity_ratio;
    real density_ratio;

    real mac_reduction;
    real external_traffic_reduction;

    real macs_per_compute_cycle;
    real cycles_per_mac;
    real mac_utilisation;

    real non_mac_percentage;

    real results_per_compute_cycle;
    real cycles_per_result;

    real scratchpad_bandwidth;

    //==========================================================================
    // Event Flags
    //==========================================================================

    logic transfer_start_seen;
    logic transfer_done_seen;

    logic compute_start_seen;
    logic sparse_compute_start_seen;
    logic compute_done_seen;

    //==========================================================================
    // Initialize Test Data
    //==========================================================================

    task automatic initialize_test_data;

        integer r;
        integer c;
        integer idx;

        begin

            //---------------------------------------------------------------------- 
            // Compressed A.
            //----------------------------------------------------------------------

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

            //---------------------------------------------------------------------- 
            // Dense B.
            //----------------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 1)
                    B[r][c] = (r * 8) + c + 1;
            end

            //---------------------------------------------------------------------- 
            // 2:4 metadata.
            //----------------------------------------------------------------------

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

            //---------------------------------------------------------------------- 
            // Clear memory image.
            //----------------------------------------------------------------------

            for (idx = 0; idx < TOTAL_WORDS; idx = idx + 1)
                memory_image[idx] = 32'd0;

            //---------------------------------------------------------------------- 
            // Pack compressed A.
            //----------------------------------------------------------------------

            idx = 0;

            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    memory_image[idx] = A[r][c];
                    idx = idx + 1;
                end
            end

            //---------------------------------------------------------------------- 
            // Pack dense B.
            //----------------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin
                for (c = 0; c < 8; c = c + 1) begin
                    memory_image[idx] = B[r][c];
                    idx = idx + 1;
                end
            end

            //---------------------------------------------------------------------- 
            // Pack metadata.
            //----------------------------------------------------------------------

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
    // Clear Research Counters
    //==========================================================================

    task automatic clear_counters;

        begin

            errors = 0;

            cycle_counter = 0;

            test_start_cycle = -1;

            transfer_start_cycle = -1;
            transfer_done_cycle = -1;

            compute_start_cycle = -1;
            sparse_compute_start_cycle = -1;
            compute_busy_start_cycle = -1;
            compute_wait_cycles = 0;
            compute_done_cycle = -1;

            transfer_cycles = 0;
            operand_read_cycles = 0;
            compute_cycles = 0;
            end_to_end_cycles = 0;

            mem_request_count = 0;
            mem_response_count = 0;
            rlast_count = 0;

            result_count = 0;
            result_mismatch_count = 0;

            a_read_count = 0;
            b_read_count = 0;
            metadata_read_count = 0;

            external_bytes_transferred = 0;

            total_spad_reads = 0;
            spad_bytes_read = 0;

            zero_mac_avoided = 0;
            non_mac_cycles = 0;

            transfer_start_seen = 1'b0;
            transfer_done_seen = 1'b0;

            compute_start_seen = 1'b0;
            sparse_compute_start_seen = 1'b0;
            compute_done_seen = 1'b0;

        end

    endtask

    //==========================================================================
    // Build Sparse Request
    //==========================================================================

    task automatic build_sparse_request;

        begin

            sparse_tile_request = '0;

            sparse_tile_request.valid     = 1'b1;
            sparse_tile_request.last_tile = 1'b1;

            sparse_tile_request.tile_context.tile_row = 16'd0;
            sparse_tile_request.tile_context.tile_col = 16'd0;
            sparse_tile_request.tile_context.tile_k   = 16'd0;

            // Main-memory layout.
            //
            // A        : bytes   0..127
            // B        : bytes 128..383
            // metadata : bytes 384..447

            sparse_tile_request.values_addr_a   = 32'd0;
            sparse_tile_request.values_addr_b   = 32'd128;
            sparse_tile_request.metadata_addr_a = 32'd384;
            sparse_tile_request.addr_c          = 32'd448;

            sparse_tile_request.rows   = 16'd8;
            sparse_tile_request.cols   = 16'd8;
            sparse_tile_request.k_size = 16'd8;

            sparse_tile_request.stride_a = 16'd4;
            sparse_tile_request.stride_b = 16'd8;

            sparse_tile_request.bank_a        = 4'd0;
            sparse_tile_request.bank_b        = 4'd1;
            sparse_tile_request.metadata_bank = 4'd2;
            sparse_tile_request.bank_c        = 4'd3;

            sparse_tile_request.transfer_bytes_a =
                32'd128;

            sparse_tile_request.transfer_bytes_b =
                32'd256;

            sparse_tile_request.metadata_transfer_bytes =
                32'd64;

        end

    endtask

    //==========================================================================
    // Reset
    //==========================================================================

    task automatic reset_dut;

        begin

            rst = 1'b1;

            sparse_tile_request_valid = 1'b0;
            compute_start = 1'b0;

            repeat (5)
                @(posedge clk);

            rst = 1'b0;

            repeat (2)
                @(posedge clk);

        end

    endtask

    //==========================================================================
    // Main Memory Model
    //
    // The request channel is always ready.
    //
    // A request is accepted once, then exactly request_bytes/8 response beats
    // are generated.
    //
    // This is intentionally the same functional memory behavior used by the
    // verified sparse datapath TB.
    //==========================================================================

    assign mem_req_ready = 1'b1;

    always @(posedge clk) begin

        if (rst) begin

            mem_rvalid = 1'b0;
            mem_rdata  = 64'd0;
            mem_rlast  = 1'b0;

            memory_sending = 1'b0;

            memory_word_index = 0;
            memory_beat_index = 0;
            memory_request_bytes = 0;

        end

        else begin

            mem_rvalid = 1'b0;
            mem_rlast  = 1'b0;

            //------------------------------------------------------------------
            // Accept request.
            //------------------------------------------------------------------

            if (mem_req_valid &&
                mem_req_ready &&
                !memory_sending) begin

                memory_sending = 1'b1;

                memory_word_index =
                    mem_req_addr / 4;

                memory_beat_index = 0;

                memory_request_bytes =
                    mem_req_bytes;

                mem_request_count =
                    mem_request_count + 1;

                external_bytes_transferred =
                    external_bytes_transferred +
                    mem_req_bytes;

                $display(
                    "[MEM_REQ] t=%0t addr=%08h bytes=%0d beats=%0d",
                    $time,
                    mem_req_addr,
                    mem_req_bytes,
                    mem_req_bytes / 8
                );

            end

            //------------------------------------------------------------------
            // Return response beat.
            //------------------------------------------------------------------

            if (memory_sending) begin

                mem_rvalid = 1'b1;

                mem_rdata[31:0] =
                    memory_image[memory_word_index];

                mem_rdata[63:32] =
                    memory_image[memory_word_index + 1];

                mem_response_count =
                    mem_response_count + 1;

                if (memory_beat_index ==
                    ((memory_request_bytes / 8) - 1)) begin

                    mem_rlast = 1'b1;

                    rlast_count =
                        rlast_count + 1;

                    memory_sending = 1'b0;

                end

                else begin

                    memory_word_index =
                        memory_word_index + 2;

                    memory_beat_index =
                        memory_beat_index + 1;

                end

            end

        end

    end

    //==========================================================================
    // Research Event Monitor
    //
    // Hierarchical signals are used only for measurement:
    //
    //   dut.sparse_a_en
    //   dut.sparse_b_en
    //   dut.sparse_metadata_en
    //   dut.sparse_compute_start
    //
    // No functional RTL is modified.
    //==========================================================================

    always @(posedge clk) begin

        if (!rst) begin

            cycle_counter =
                cycle_counter + 1;

            //------------------------------------------------------------------
            // Transfer start.
            //------------------------------------------------------------------

            if (transfer_busy &&
                !transfer_start_seen) begin

                transfer_start_seen =
                    1'b1;

                transfer_start_cycle =
                    cycle_counter;

            end

            //------------------------------------------------------------------
            // Transfer completion.
            //------------------------------------------------------------------

            if (transfer_done &&
                !transfer_done_seen) begin

                transfer_done_seen =
                    1'b1;

                transfer_done_cycle =
                    cycle_counter;

            end

            //------------------------------------------------------------------
            // External memory request.
            //
            // Counted in the memory model itself. This monitor does not
            // duplicate the request count.
            //------------------------------------------------------------------

            //------------------------------------------------------------------
            // Sparse compute controller start.
            //
            // The wrapper exposes sparse_compute_start internally as the
            // transition from operand-read FSM completion into compute.
            //------------------------------------------------------------------

            if (dut.sparse_compute_start &&
                !sparse_compute_start_seen) begin

                sparse_compute_start_seen =
                    1'b1;

                sparse_compute_start_cycle =
                    cycle_counter;

            end

            //------------------------------------------------------------------
            // Compute done.
            //------------------------------------------------------------------

            if (compute_done &&
                !compute_done_seen) begin

                compute_done_seen =
                    1'b1;

                compute_done_cycle =
                    cycle_counter;

            end

            //------------------------------------------------------------------
            // Scratchpad A read.
            //------------------------------------------------------------------

            if (dut.sparse_a_en &&
                !dut.sparse_a_we)
                a_read_count =
                    a_read_count + 1;

            //------------------------------------------------------------------
            // Scratchpad B read.
            //------------------------------------------------------------------

            if (dut.sparse_b_en &&
                !dut.sparse_b_we)
                b_read_count =
                    b_read_count + 1;

            //------------------------------------------------------------------
            // Scratchpad metadata read.
            //------------------------------------------------------------------

            if (dut.sparse_metadata_en &&
                !dut.sparse_metadata_we)
                metadata_read_count =
                    metadata_read_count + 1;

        end

    end

    //==========================================================================
    // Result Verification
    //
    // The sparse wrapper exposes the completed result as compute_result[8][8].
    // There is no result_valid/row/col/data streaming interface, so result
    // ordering cannot be independently observed here. We verify the complete
    // indexed matrix instead.
    //==========================================================================

    task automatic verify_results;

        integer r;
        integer c;

        begin

            result_count = 0;
            result_mismatch_count = 0;

            $display("");
            $display("============================================================");
            $display("                 SPARSE 8x8 RESULT");
            $display("============================================================");

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

                for (c = 0; c < 8; c = c + 1) begin

                    if (^compute_result[r][c] === 1'bx) begin

                        result_mismatch_count =
                            result_mismatch_count + 1;

                        $display(
                            "[FAIL] C[%0d][%0d] = X/Z",
                            r,
                            c
                        );

                    end

                    else if (compute_result[r][c] !==
                             EXPECTED_C[r][c]) begin

                        result_mismatch_count =
                            result_mismatch_count + 1;

                        $display(
                            "[FAIL] C[%0d][%0d] expected %0d got %0d",
                            r,
                            c,
                            EXPECTED_C[r][c],
                            compute_result[r][c]
                        );

                    end

                    result_count =
                        result_count + 1;

                end

            end

            if ((result_count == EXPECTED_RESULTS) &&
                (result_mismatch_count == 0)) begin

                $display("[PASS] All 64 output elements match");

            end

            else begin

                $display(
                    "[FAIL] Result verification has %0d mismatches",
                    result_mismatch_count
                );

                errors =
                    errors + 1;

            end

        end

    endtask

    //==========================================================================
    // Captured Operand Verification
    //==========================================================================

    task automatic verify_captured_operands;

        integer r;
        integer c;

        begin

            $display("");
            $display("============================================================");
            $display("              CAPTURED OPERAND VERIFICATION");
            $display("============================================================");

            //------------------------------------------------------------------
            // Compressed A.
            //------------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 4; c = c + 1) begin

                    if (^dut.sparse_a[r][c] === 1'bx) begin

                        $display(
                            "[FAIL] A[%0d][%0d] = X/Z",
                            r,
                            c
                        );

                        errors =
                            errors + 1;

                    end

                    else if (dut.sparse_a[r][c] !==
                             A[r][c]) begin

                        $display(
                            "[FAIL] A[%0d][%0d] expected %0d got %0d",
                            r,
                            c,
                            A[r][c],
                            dut.sparse_a[r][c]
                        );

                        errors =
                            errors + 1;

                    end

                end

            end

            //------------------------------------------------------------------
            // Dense B.
            //------------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 8; c = c + 1) begin

                    if (^dut.dense_b[r][c] === 1'bx) begin

                        $display(
                            "[FAIL] B[%0d][%0d] = X/Z",
                            r,
                            c
                        );

                        errors =
                            errors + 1;

                    end

                    else if (dut.dense_b[r][c] !==
                             B[r][c]) begin

                        $display(
                            "[FAIL] B[%0d][%0d] expected %0d got %0d",
                            r,
                            c,
                            B[r][c],
                            dut.dense_b[r][c]
                        );

                        errors =
                            errors + 1;

                    end

                end

            end

            //------------------------------------------------------------------
            // Metadata.
            //------------------------------------------------------------------

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 2; c = c + 1) begin

                    if (^dut.sparse_metadata[r][c] === 1'bx) begin

                        $display(
                            "[FAIL] META[%0d][%0d] = X/Z",
                            r,
                            c
                        );

                        errors =
                            errors + 1;

                    end

                    else if (dut.sparse_metadata[r][c] !==
                             META[r][c]) begin

                        $display(
                            "[FAIL] META[%0d][%0d] expected %03b got %03b",
                            r,
                            c,
                            META[r][c],
                            dut.sparse_metadata[r][c]
                        );

                        errors =
                            errors + 1;

                    end

                end

            end

            if (errors == 0)
                $display("[PASS] All captured operands match");

        end

    endtask

    //==========================================================================
    // Calculate Research Metrics
    //==========================================================================

    task automatic calculate_metrics;

        begin

            //------------------------------------------------------------------
            // Timing.
            //------------------------------------------------------------------

            if ((transfer_start_cycle >= 0) &&
                (transfer_done_cycle >= 0)) begin

                transfer_cycles =
                    transfer_done_cycle -
                    transfer_start_cycle;

            end
            else begin
                transfer_cycles = 0;
            end

            if ((compute_start_cycle >= 0) &&
                (sparse_compute_start_cycle >= 0)) begin

                operand_read_cycles =
                    sparse_compute_start_cycle -
                    compute_start_cycle;

            end
            else begin
                operand_read_cycles = 0;
            end

            if ((sparse_compute_start_cycle >= 0) &&
                (compute_done_cycle >= 0)) begin

                compute_cycles =
                    compute_done_cycle -
                    sparse_compute_start_cycle;

            end
            else begin
                compute_cycles = 0;
            end

            if ((test_start_cycle >= 0) &&
                (compute_done_cycle >= 0)) begin

                end_to_end_cycles =
                    compute_done_cycle -
                    test_start_cycle;

            end
            else begin
                end_to_end_cycles = 0;
            end

            //------------------------------------------------------------------
            // Scratchpad traffic.
            //------------------------------------------------------------------

            total_spad_reads =
                a_read_count +
                b_read_count +
                metadata_read_count;

            spad_bytes_read =
                total_spad_reads *
                ELEMENT_BYTES;

            //------------------------------------------------------------------
            // Sparsity.
            //------------------------------------------------------------------

            sparsity_ratio = 0.50;
            density_ratio = 0.50;

            zero_mac_avoided =
                DENSE_MAC_OPPORTUNITIES -
                compute_mac_count;

            mac_reduction =
                (1.0 -
                 (real'(compute_mac_count) /
                  real'(DENSE_MAC_OPPORTUNITIES))) *
                100.0;

            //------------------------------------------------------------------
            // Compute efficiency.
            //
            // One MAC unit => peak = 1 MAC/cycle.
            //------------------------------------------------------------------

            if ((compute_cycles > 0) &&
                (compute_mac_count > 0)) begin

                macs_per_compute_cycle =
                    real'(compute_mac_count) /
                    real'(compute_cycles);

                cycles_per_mac =
                    real'(compute_cycles) /
                    real'(compute_mac_count);

                mac_utilisation =
                    macs_per_compute_cycle *
                    100.0;

                non_mac_cycles =
                    compute_cycles -
                    compute_mac_count;

                non_mac_percentage =
                    real'(non_mac_cycles) /
                    real'(compute_cycles) *
                    100.0;

                results_per_compute_cycle =
                    real'(result_count) /
                    real'(compute_cycles);

                cycles_per_result =
                    real'(compute_cycles) /
                    real'(result_count);

                scratchpad_bandwidth =
                    real'(spad_bytes_read) /
                    real'(compute_cycles);

            end
            else begin

                macs_per_compute_cycle = 0.0;
                cycles_per_mac = 0.0;
                mac_utilisation = 0.0;

                non_mac_cycles = 0;
                non_mac_percentage = 0.0;

                results_per_compute_cycle = 0.0;
                cycles_per_result = 0.0;

                scratchpad_bandwidth = 0.0;

            end

            //------------------------------------------------------------------
            // External traffic reduction.
            //
            // Dense baseline = 512 B.
            // Sparse traffic includes A + B + metadata = 448 B.
            //------------------------------------------------------------------

            external_traffic_reduction =
                (1.0 -
                 (real'(external_bytes_transferred) /
                  real'(DENSE_EXTERNAL_BYTES))) *
                100.0;

        end

    endtask

    //==========================================================================
    // Research Metrics Report
    //==========================================================================

    task automatic report_metrics;

        begin

            calculate_metrics();

            $display("");
            $display("============================================================");
            $display("              SPARSE 8x8 RESEARCH METRICS");
            $display("============================================================");

            $display("");
            $display("FUNCTIONAL CORRECTNESS");
            $display("------------------------------------------------------------");

            $display(
                "Matrix size                  : 8x8"
            );

            $display(
                "Results produced             : %0d / %0d",
                result_count,
                EXPECTED_RESULTS
            );

            $display(
                "Value mismatches             : %0d",
                result_mismatch_count
            );

            $display(
                "Functional status            : %s",
                ((result_count == EXPECTED_RESULTS) &&
                 (result_mismatch_count == 0)) ?
                 "PASS" : "FAIL"
            );

            $display("");
            $display("SPARSITY");
            $display("------------------------------------------------------------");

            $display(
                "Structured sparsity          : 2:4"
            );

            $display(
                "Sparsity ratio               : %0.2f%%",
                sparsity_ratio * 100.0
            );

            $display(
                "Density                      : %0.2f%%",
                density_ratio * 100.0
            );

            $display(
                "Dense MAC opportunities      : %0d",
                DENSE_MAC_OPPORTUNITIES
            );

            $display(
                "Sparse executed MACs         : %0d",
                compute_mac_count
            );

            $display(
                "Zero MACs avoided            : %0d",
                zero_mac_avoided
            );

            $display(
                "MAC reduction                : %0.2f%%",
                mac_reduction
            );

            $display("");
            $display("EXTERNAL MEMORY");
            $display("------------------------------------------------------------");

            $display(
                "Memory requests              : %0d",
                mem_request_count
            );

            $display(
                "Memory response beats        : %0d",
                mem_response_count
            );

            $display(
                "RLAST count                  : %0d",
                rlast_count
            );

            $display(
                "External bytes transferred   : %0d B",
                external_bytes_transferred
            );

            $display(
                "Dense baseline traffic       : %0d B",
                DENSE_EXTERNAL_BYTES
            );

            $display(
                "External traffic reduction   : %0.2f%%",
                external_traffic_reduction
            );

            $display(
                "Transfer cycles              : %0d",
                transfer_cycles
            );

            $display("");
            $display("SCRATCHPAD");
            $display("------------------------------------------------------------");

            $display(
                "A scratchpad reads           : %0d",
                a_read_count
            );

            $display(
                "B scratchpad reads           : %0d",
                b_read_count
            );

            $display(
                "Metadata reads               : %0d",
                metadata_read_count
            );

            $display(
                "Total scratchpad reads       : %0d",
                total_spad_reads
            );

            $display(
                "Scratchpad bytes read        : %0d B",
                spad_bytes_read
            );

            $display(
                "Average SPAD bandwidth      : %0.6f B/cycle",
                scratchpad_bandwidth
            );

            $display("");
            $display("COMPUTE");
            $display("------------------------------------------------------------");

            $display(
                "Compute start cycle          : %0d",
                compute_start_cycle
            );

            $display(
                "Sparse compute start cycle   : %0d",
                sparse_compute_start_cycle
            );

            $display(
                "Compute done cycle           : %0d",
                compute_done_cycle
            );

            $display(
                "Operand-read cycles          : %0d",
                operand_read_cycles
            );

            $display(
                "Sparse compute cycles        : %0d",
                compute_cycles
            );

            $display(
                "MAC operations               : %0d",
                compute_mac_count
            );

            $display(
                "Theoretical peak             : 1 MAC/cycle"
            );

            $display(
                "MACs / compute cycle         : %0.6f",
                macs_per_compute_cycle
            );

            $display(
                "Cycles / MAC                 : %0.6f",
                cycles_per_mac
            );

            $display(
                "MAC utilisation              : %0.6f%%",
                mac_utilisation
            );

            $display(
                "Non-MAC compute cycles       : %0d",
                non_mac_cycles
            );

            $display(
                "Non-MAC percentage           : %0.6f%%",
                non_mac_percentage
            );

            $display(
                "Results / compute cycle      : %0.6f",
                results_per_compute_cycle
            );

            $display(
                "Cycles / result              : %0.6f",
                cycles_per_result
            );

            $display("");
            $display("END-TO-END");
            $display("------------------------------------------------------------");

            $display(
                "Test start cycle             : %0d",
                test_start_cycle
            );

            $display(
                "Transfer start cycle         : %0d",
                transfer_start_cycle
            );

            $display(
                "Transfer done cycle          : %0d",
                transfer_done_cycle
            );

            $display(
                "End-to-end cycles            : %0d",
                end_to_end_cycles
            );

            $display("");
            $display("NOTE");
            $display("------------------------------------------------------------");
            $display(
                "Result ordering is not independently measurable because"
            );
            $display(
                "the sparse wrapper exposes an indexed result matrix rather"
            );
            $display(
                "than a streaming result_valid/row/col interface."
            );

            $display("============================================================");
            $display("");

        end

    endtask

    //==========================================================================
    // Research Sanity Checks
    //==========================================================================

    task automatic run_sanity_checks;

        begin

            $display("");
            $display("============================================================");
            $display("                    SANITY CHECKS");
            $display("============================================================");

            if (mem_request_count == 4)
                $display("[PASS] External memory requests = 4");
            else begin
                $display(
                    "[FAIL] External memory requests expected 4 got %0d",
                    mem_request_count
                );
                errors = errors + 1;
            end

            if (mem_response_count == TOTAL_BEATS)
                $display(
                    "[PASS] External response beats = %0d",
                    TOTAL_BEATS
                );
            else begin
                $display(
                    "[FAIL] External response beats expected %0d got %0d",
                    TOTAL_BEATS,
                    mem_response_count
                );
                errors = errors + 1;
            end

            if (external_bytes_transferred == 448)
                $display(
                    "[PASS] External bytes transferred = 448 B"
                );
            else begin
                $display(
                    "[FAIL] External bytes expected 448 got %0d",
                    external_bytes_transferred
                );
                errors = errors + 1;
            end

            if (rlast_count == 4)
                $display("[PASS] RLAST count = 4");
            else begin
                $display(
                    "[FAIL] RLAST count expected 4 got %0d",
                    rlast_count
                );
                errors = errors + 1;
            end

            if (a_read_count == 32)
                $display("[PASS] A scratchpad reads = 32");
            else begin
                $display(
                    "[FAIL] A scratchpad reads expected 32 got %0d",
                    a_read_count
                );
                errors = errors + 1;
            end

            if (b_read_count == 64)
                $display("[PASS] B scratchpad reads = 64");
            else begin
                $display(
                    "[FAIL] B scratchpad reads expected 64 got %0d",
                    b_read_count
                );
                errors = errors + 1;
            end

            if (metadata_read_count == 16)
                $display("[PASS] Metadata reads = 16");
            else begin
                $display(
                    "[FAIL] Metadata reads expected 16 got %0d",
                    metadata_read_count
                );
                errors = errors + 1;
            end

            if (compute_mac_count == SPARSE_EXPECTED_MACS)
                $display(
                    "[PASS] Sparse MAC count = %0d",
                    compute_mac_count
                );
            else begin
                $display(
                    "[FAIL] Sparse MAC count expected %0d got %0d",
                    SPARSE_EXPECTED_MACS,
                    compute_mac_count
                );
                errors = errors + 1;
            end

            if ((result_count == EXPECTED_RESULTS) &&
                (result_mismatch_count == 0))
                $display("[PASS] All 64 output elements match");
            else begin
                $display(
                    "[FAIL] Result verification failed"
                );
                errors = errors + 1;
            end

            if (transfer_start_cycle >= 0 &&
                transfer_done_cycle >= 0)
                $display("[PASS] Transfer timing captured");
            else begin
                $display("[FAIL] Transfer timing not captured");
                errors = errors + 1;
            end

            if (compute_start_cycle >= 0 &&
                sparse_compute_start_cycle >= 0 &&
                compute_done_cycle >= 0)
                $display("[PASS] Compute timing captured");
            else begin
                $display("[FAIL] Compute timing not fully captured");
                errors = errors + 1;
            end

            $display("============================================================");
            $display("");

        end

    endtask

    //==========================================================================
    // Main Test
    //
    // IMPORTANT:
    // This sequence intentionally follows the already-verified sparse
    // functional TB. compute_start is held until the wrapper has actually
    // left READ_IDLE. This is required because transfer_complete_latched is
    // a registered signal inside the wrapper.
    //==========================================================================

    initial begin

        sparse_tile_request       = '0;
        sparse_tile_request_valid = 1'b0;
        compute_start             = 1'b0;

        initialize_test_data();
        initialize_expected();
        clear_counters();

        $display("");
        $display("============================================================");
        $display("        SPARSE 8x8 RESEARCH MEASUREMENT TEST");
        $display("============================================================");

        //----------------------------------------------------------------------
        // Reset.
        //----------------------------------------------------------------------

        reset_dut();
        build_sparse_request();

        //----------------------------------------------------------------------
        // Test reference cycle.
        //----------------------------------------------------------------------

        @(negedge clk);
        test_start_cycle = cycle_counter;

        //----------------------------------------------------------------------
        // Submit request using the proven falling-edge handshake.
        //----------------------------------------------------------------------

        sparse_tile_request_valid = 1'b1;

        while (!sparse_tile_request_ready)
            @(negedge clk);

        @(posedge clk);

        $display("[PASS] Sparse request accepted");

        @(negedge clk);
        sparse_tile_request_valid = 1'b0;

        //----------------------------------------------------------------------
        // Wait for transfer start/completion.
        //----------------------------------------------------------------------

        while (!transfer_start_seen)
            @(posedge clk);

        while (!transfer_done_seen)
            @(posedge clk);

        transfer_cycles =
            transfer_done_cycle - transfer_start_cycle;

        $display(
            "[PASS] Transfer completed in %0d cycles",
            transfer_cycles
        );

        //----------------------------------------------------------------------
        // IMPORTANT: allow transfer_done to propagate into the registered
        // transfer_complete_latched signal in the wrapper.
        //----------------------------------------------------------------------

        @(posedge clk);

        //----------------------------------------------------------------------
        // Start operand-read FSM.
        //
        // DO NOT release compute_start after only one rising edge.
        // The wrapper samples transfer_complete_latched, which is registered.
        // If it is still zero, keep compute_start asserted for another edge.
        //----------------------------------------------------------------------

        @(negedge clk);

        compute_start_cycle = cycle_counter;
        compute_start       = 1'b1;

        $display(
            "[DBG] compute_start ASSERTED at cycle %0d",
            cycle_counter
        );

        @(posedge clk);

        @(negedge clk);

        if (dut.read_state == 0) begin

            $display(
                "[DBG] READ FSM still IDLE; holding compute_start"
            );

            compute_start = 1'b1;

            @(posedge clk);

            @(negedge clk);

        end

        if (dut.read_state == 0) begin

            $display("");
            $display("[FAIL] Wrapper did not accept compute_start");
            $display(
                "[DBG] transfer_complete_latched = %b",
                dut.transfer_complete_latched
            );
            $display(
                "[DBG] read_state = %0d",
                dut.read_state
            );
            $display("");

            errors = errors + 1;
            $finish;

        end

        compute_start = 1'b0;

        $display(
            "[DBG] compute_start DEASSERTED at cycle %0d",
            cycle_counter
        );

        //======================================================================
// WAIT FOR COMPUTE DONE
//======================================================================

compute_wait_cycles = 0;

while ((compute_done !== 1'b1) &&
       (compute_wait_cycles < 2500)) begin

    @(posedge clk);

    compute_wait_cycles =
        compute_wait_cycles + 1;
end

if (compute_done !== 1'b1) begin

    $display("");
    $display("============================================================");
    $display("[FAIL] Timeout waiting for compute_done");
    $display("============================================================");

    $display(
        "[DBG] waited cycles = %0d",
        compute_wait_cycles
    );

    $display(
        "[DBG] read_state = %0d",
        dut.read_state
    );

    $display(
        "[DBG] compute_busy = %b",
        compute_busy
    );

    $display(
        "[DBG] compute_done = %b",
        compute_done
    );

    $display(
        "[DBG] MAC count = %0d",
        compute_mac_count
    );

    errors = errors + 1;

    $finish;

end

else begin

    compute_cycles =
        compute_done_cycle -
        compute_busy_start_cycle;

    $display(
        "[PASS] Sparse compute completed at cycle %0d",
        compute_done_cycle
    );

    $display(
        "[METRIC] Sparse compute cycles = %0d",
        compute_cycles
    );

end

        //----------------------------------------------------------------------
        // Operand capture can now be checked.
        //----------------------------------------------------------------------

        verify_captured_operands();

        //----------------------------------------------------------------------
        // Wait for compute_done.
        //
        // compute_done is a one-cycle pulse. Poll it on clock boundaries,
        // with a bounded timeout so the TB can never hang indefinitely.
        //----------------------------------------------------------------------

        compute_wait_cycles = 0;

        while ((compute_done !== 1'b1) &&
               (compute_wait_cycles < 2500)) begin

            @(posedge clk);
            compute_wait_cycles = compute_wait_cycles + 1;

        end

        if (compute_done !== 1'b1) begin

            $display("");
            $display("============================================================");
            $display("[FAIL] Timeout waiting for compute_done");
            $display("============================================================");
            $display("[DBG] waited cycles = %0d", compute_wait_cycles);
            $display("[DBG] compute_busy  = %b", compute_busy);
            $display("[DBG] compute_done  = %b", compute_done);
            $display("[DBG] MAC count     = %0d", compute_mac_count);
            $display("============================================================");

            errors = errors + 1;
            $finish;

        end

        compute_done_cycle = cycle_counter;

        compute_cycles =
            compute_done_cycle - compute_busy_start_cycle;

        compute_done_seen = 1'b1;

        $display(
            "[PASS] Sparse compute completed at cycle %0d",
            compute_done_cycle
        );

        $display(
            "[METRIC] Sparse compute cycles = %0d",
            compute_cycles
        );

        //----------------------------------------------------------------------
        // Let final matrix values settle.
        //----------------------------------------------------------------------

        @(posedge clk);

        //----------------------------------------------------------------------
        // Functional verification.
        //----------------------------------------------------------------------

        verify_results();

        //----------------------------------------------------------------------
        // Calculate and report research metrics.
        //----------------------------------------------------------------------

        calculate_metrics();
        report_metrics();

        //----------------------------------------------------------------------
        // Final sanity checks.
        //----------------------------------------------------------------------

        run_sanity_checks();

        $display("");
        $display("============================================================");
        $display("FINAL STATUS");
        $display("============================================================");

        if ((errors == 0) &&
            (result_count == EXPECTED_RESULTS) &&
            (result_mismatch_count == 0) &&
            (compute_mac_count == SPARSE_EXPECTED_MACS)) begin

            $display(
                "SPARSE 8x8 RESEARCH MEASUREMENT : PASS"
            );

        end
        else begin

            $display(
                "SPARSE 8x8 RESEARCH MEASUREMENT : FAIL"
            );

        end

        $display("Errors = %0d", errors);
        $display("============================================================");

        $finish;

    end

endmodule

`default_nettype wire
