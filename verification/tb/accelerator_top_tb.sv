//==============================================================================
// Testbench   : accelerator_top_tb  (research-instrumented variant)
//
// Description :
//   Same DUT and same two descriptors as the original integration test
//   (job 0 = sparse 8x8, job 1 = dense 8x8, both against known-good golden
//   matrices), but the reporting layer is rebuilt for extracting research
//   data rather than just pass/fail:
//
//     - All module-internal debug traces (READDBG, MEM Beat/Request Accepted)
//       are silenced by instantiating the DUT with VERBOSE=0. Those prints
//       live inside sparse_datapath_8x8_wrapper.sv and main_memory_model.sv
//       themselves, gated behind a VERBOSE parameter threaded down through
//       accelerator_top -> scheduler_engine -> {dense,sparse}_subsystem_wrapper
//       -> the two RTL files. Set VERBOSE=1 below to get the old trace back
//       for debugging; it changes zero functional behavior either way.
//
//     - Both jobs' results are shown as full 8x8 side-by-side matrices
//       (golden vs. measured, with a per-row match/mismatch marker), not
//       a scrolling list of individual [FAIL] lines.
//
//     - A metrics table at the end reports, per job: issue-to-done latency
//       in both simulation time and clock cycles, MAC count, and (for the
//       sparse job specifically) the realized MAC reduction versus a dense
//       8x8x8 tile (512 MACs) -- the actual 2:4 structured-sparsity payoff
//       this run measured, not a theoretical number.
//
//   Everything measured here is either read directly off DUT ports/signals
//   or computed from values the DUT produced this run -- nothing is
//   hard-coded except the golden matrices and the descriptors themselves.
//==============================================================================

`timescale 1ns/1ps

import descriptor_pkg::*;
import dma_pkg::*;

module accelerator_top_tb;

    //==========================================================================
    // Clock / Reset
    //==========================================================================

    localparam time CLK_PERIOD = 10ns;

    logic clk;
    logic rst;

    always #(CLK_PERIOD/2) clk = ~clk;

    //==========================================================================
    // DUT Connections
    //==========================================================================

    logic run;
    logic [DESC_INDEX_WIDTH-1:0] job_index_in;
    logic [5:0]                  result_read_index_in;
    logic signed [63:0]          result_read_data_out;
    logic all_done;
    logic any_error;

    logic                          cpu_we;
    logic [DESC_INDEX_WIDTH-1:0]   cpu_desc_idx;
    logic [WORD_COUNTER_WIDTH-1:0] cpu_word_offset;
    descriptor_mem_word_t          cpu_wdata;

    logic               debug_dense_result_valid;
    logic [15:0]        debug_dense_result_row;
    logic [15:0]        debug_dense_result_col;
    logic signed [63:0] debug_dense_result_data;
    logic [31:0]        debug_dense_mac_count;

    logic signed [63:0] debug_sparse_result [0:7][0:7];
    logic [31:0]        debug_sparse_mac_count;

    logic [DESC_INDEX_WIDTH-1:0] debug_current_job_index;
    job_status_t                 debug_job_status;

    // Set to 1 to bring back the original per-cycle READDBG / MEM traces
    // from sparse_datapath_8x8_wrapper.sv and main_memory_model.sv.
    localparam bit VERBOSE = 1'b0;

    accelerator_top #(
        .NUM_JOBS (2),
        .VERBOSE  (VERBOSE)
    ) dut (

        .clk (clk),
        .rst (rst),

        .run          (run),
        .job_index_in (job_index_in),
        .all_done     (all_done),
        .any_error    (any_error),

        .cpu_we          (cpu_we),
        .cpu_desc_idx    (cpu_desc_idx),
        .cpu_word_offset (cpu_word_offset),
        .cpu_wdata       (cpu_wdata),

        .debug_dense_result_valid (debug_dense_result_valid),
        .debug_dense_result_row   (debug_dense_result_row),
        .debug_dense_result_col   (debug_dense_result_col),
        .debug_dense_result_data  (debug_dense_result_data),
        .debug_dense_mac_count    (debug_dense_mac_count),

        .debug_sparse_result    (debug_sparse_result),
        .debug_sparse_mac_count (debug_sparse_mac_count),

        .result_read_index_in (result_read_index_in),
        .result_read_data_out (result_read_data_out),

        .debug_current_job_index (debug_current_job_index),
        .debug_job_status        (debug_job_status)
    );

    //==========================================================================
    // Golden Matrices
    //==========================================================================

    logic signed [63:0] expected_sparse_c [0:7][0:7];
    logic signed [63:0] expected_dense_c  [0:7][0:7];

    initial begin
        expected_sparse_c[0][0]=-14; expected_sparse_c[0][1]=-2; expected_sparse_c[0][2]=-13; expected_sparse_c[0][3]=23;
        expected_sparse_c[0][4]=-49; expected_sparse_c[0][5]=45; expected_sparse_c[0][6]=-44; expected_sparse_c[0][7]=60;

        expected_sparse_c[1][0]=58; expected_sparse_c[1][1]=44; expected_sparse_c[1][2]=41; expected_sparse_c[1][3]=-82;
        expected_sparse_c[1][4]=34; expected_sparse_c[1][5]=51; expected_sparse_c[1][6]=25; expected_sparse_c[1][7]=11;

        expected_sparse_c[2][0]=6; expected_sparse_c[2][1]=-14; expected_sparse_c[2][2]=29; expected_sparse_c[2][3]=78;
        expected_sparse_c[2][4]=-90; expected_sparse_c[2][5]=17; expected_sparse_c[2][6]=-19; expected_sparse_c[2][7]=68;

        expected_sparse_c[3][0]=28; expected_sparse_c[3][1]=-18; expected_sparse_c[3][2]=-32; expected_sparse_c[3][3]=-12;
        expected_sparse_c[3][4]=74; expected_sparse_c[3][5]=34; expected_sparse_c[3][6]=-29; expected_sparse_c[3][7]=17;

        expected_sparse_c[4][0]=55; expected_sparse_c[4][1]=-62; expected_sparse_c[4][2]=26; expected_sparse_c[4][3]=-37;
        expected_sparse_c[4][4]=-40; expected_sparse_c[4][5]=-48; expected_sparse_c[4][6]=52; expected_sparse_c[4][7]=-24;

        expected_sparse_c[5][0]=30; expected_sparse_c[5][1]=13; expected_sparse_c[5][2]=-42; expected_sparse_c[5][3]=-75;
        expected_sparse_c[5][4]=-2; expected_sparse_c[5][5]=48; expected_sparse_c[5][6]=-44; expected_sparse_c[5][7]=9;

        expected_sparse_c[6][0]=72; expected_sparse_c[6][1]=0; expected_sparse_c[6][2]=-6; expected_sparse_c[6][3]=-73;
        expected_sparse_c[6][4]=21; expected_sparse_c[6][5]=50; expected_sparse_c[6][6]=-17; expected_sparse_c[6][7]=20;

        expected_sparse_c[7][0]=14; expected_sparse_c[7][1]=-32; expected_sparse_c[7][2]=-89; expected_sparse_c[7][3]=-38;
        expected_sparse_c[7][4]=59; expected_sparse_c[7][5]=-52; expected_sparse_c[7][6]=-11; expected_sparse_c[7][7]=-92;

        // Dense golden: now the SAME matrix as sparse (Option A: both
        // subsystems share one coordinated A x B, since main_memory_model
        // only has one valid address window per subsystem).
        for (int r = 0; r < 8; r++)
            for (int c = 0; c < 8; c++)
                expected_dense_c[r][c] = expected_sparse_c[r][c];
    end

    //==========================================================================
    // Dense Result Reconstruction
    //
    // Dense streams one element per debug_dense_result_valid pulse; rebuild
    // the 8x8 matrix from the (row, col, data) the DUT actually reports, so
    // the side-by-side print reflects true device behavior rather than an
    // assumed order.
    //==========================================================================

    logic signed [63:0] measured_dense_c [0:7][0:7];
    integer dense_result_count;
    integer dense_order_error_count;

    always @(posedge clk) begin
        if (rst) begin
            dense_result_count      <= 0;
            dense_order_error_count <= 0;
        end
        else if (debug_dense_result_valid) begin
            measured_dense_c[debug_dense_result_row][debug_dense_result_col]
                <= debug_dense_result_data;
            dense_result_count <= dense_result_count + 1;

            if ((debug_dense_result_row  >= 16'd8) ||
                (debug_dense_result_col  >= 16'd8))
                dense_order_error_count <= dense_order_error_count + 1;
        end
    end

    //==========================================================================
    // Per-Job Timing
    //
    // job0 = sparse (index 0), job1 = dense (index 1) for this descriptor
    // ordering.
    //==========================================================================

    // Under the old auto-loop DUT, all_done fired once at the very end and
    // job0/job1 boundaries had to be inferred from debug_current_job_index
    // ticking over. Under the new single-job-per-run DUT, all_done pulses
    // once per job and the stimulus now issues two explicit run pulses --
    // so these are just plain timestamps, set directly in the stimulus at
    // each dispatch/all_done event below, not inferred by a background monitor.
    time job0_issue_time, job0_done_time;
    time job1_issue_time, job1_done_time;

    //==========================================================================
    // Descriptor-Fetch-to-Dispatch Latency
    //
    // Time from DFU issuing its read burst (dfu_start) to the relevant
    // subsystem's compute engine actually starting -- the real front-end
    // overhead (fetch + decode + scheduler handoff) separate from compute
    // itself. Tracked per job by watching which subsystem's compute_start
    // fires first after each dfu_start pulse.
    //==========================================================================

    time job0_dfu_start_time, job0_compute_start_time;
    time job1_dfu_start_time, job1_compute_start_time;
    logic prev_dfu_start;
    logic prev_sparse_compute_start_seen, prev_dense_compute_start_seen;

    always @(posedge clk) begin
        if (rst) begin
            prev_dfu_start <= 1'b0;
            job0_dfu_start_time     <= 0;
            job0_compute_start_time <= 0;
            job1_dfu_start_time     <= 0;
            job1_compute_start_time <= 0;
            prev_sparse_compute_start_seen <= 1'b0;
            prev_dense_compute_start_seen  <= 1'b0;
        end
        else begin
            if (dut.dfu_start && !prev_dfu_start) begin
                if (debug_current_job_index == 0)
                    job0_dfu_start_time <= $time;
                else
                    job1_dfu_start_time <= $time;
            end
            prev_dfu_start <= dut.dfu_start;

            if (dut.u_scheduler_engine.u_sparse_subsystem.compute_start &&
                !prev_sparse_compute_start_seen)
            begin
                job0_compute_start_time       <= $time;
                prev_sparse_compute_start_seen <= 1'b1;
            end

            if (dut.u_scheduler_engine.u_dense_subsystem.compute_busy &&
                !prev_dense_compute_start_seen)
            begin
                job1_compute_start_time    <= $time;
                prev_dense_compute_start_seen <= 1'b1;
            end
        end
    end

    //==========================================================================
    // Transfer / Compute Phase Split
    //
    // transfer_busy/done and compute_busy/done are real ports (sparse) /
    // internal signals (dense, hierarchically tapped) on both subsystem
    // wrappers -- not estimated. Captures how many cycles each job spent
    // moving data vs. actually computing.
    //==========================================================================

    time sparse_transfer_start_t, sparse_transfer_end_t;
    time sparse_compute_busy_start_t, sparse_compute_busy_end_t;
    time dense_transfer_start_t, dense_transfer_end_t;
    time dense_compute_busy_start_t, dense_compute_busy_end_t;

    logic prev_sparse_transfer_busy, prev_sparse_compute_busy;
    logic prev_dense_transfer_busy, prev_dense_compute_busy;

    always @(posedge clk) begin
        if (rst) begin
            prev_sparse_transfer_busy <= 1'b0;
            prev_sparse_compute_busy  <= 1'b0;
            prev_dense_transfer_busy  <= 1'b0;
            prev_dense_compute_busy   <= 1'b0;
        end
        else begin
            if (dut.u_scheduler_engine.u_sparse_subsystem.transfer_busy && !prev_sparse_transfer_busy)
                sparse_transfer_start_t <= $time;
            if (!dut.u_scheduler_engine.u_sparse_subsystem.transfer_busy && prev_sparse_transfer_busy)
                sparse_transfer_end_t <= $time;
            if (dut.u_scheduler_engine.u_sparse_subsystem.compute_busy && !prev_sparse_compute_busy)
                sparse_compute_busy_start_t <= $time;
            if (!dut.u_scheduler_engine.u_sparse_subsystem.compute_busy && prev_sparse_compute_busy)
                sparse_compute_busy_end_t <= $time;

            if (dut.u_scheduler_engine.u_dense_subsystem.transfer_busy && !prev_dense_transfer_busy)
                dense_transfer_start_t <= $time;
            if (!dut.u_scheduler_engine.u_dense_subsystem.transfer_busy && prev_dense_transfer_busy)
                dense_transfer_end_t <= $time;
            if (dut.u_scheduler_engine.u_dense_subsystem.compute_busy && !prev_dense_compute_busy)
                dense_compute_busy_start_t <= $time;
            if (!dut.u_scheduler_engine.u_dense_subsystem.compute_busy && prev_dense_compute_busy)
                dense_compute_busy_end_t <= $time;

            prev_sparse_transfer_busy <= dut.u_scheduler_engine.u_sparse_subsystem.transfer_busy;
            prev_sparse_compute_busy  <= dut.u_scheduler_engine.u_sparse_subsystem.compute_busy;
            prev_dense_transfer_busy  <= dut.u_scheduler_engine.u_dense_subsystem.transfer_busy;
            prev_dense_compute_busy   <= dut.u_scheduler_engine.u_dense_subsystem.compute_busy;
        end
    end

    //==========================================================================
    // Memory Traffic (bytes actually DMA'd, per operand)
    //
    // transfer_engine splits any operand larger than BURST_BYTES (128) into
    // multiple separate mem_req handshakes -- e.g. dense's 256B B operand
    // arrives as two 128B requests, not one. Classifying by REQUEST ORDER
    // undercounts/mislabels operands as soon as any of them chunk. Classify
    // by address window instead (A/B/metadata windows are fixed, known
    // constants from this test's own descriptors), which is correct
    // regardless of how many chunks a given operand takes.
    //==========================================================================

    localparam logic [31:0] WIN_A_LO    = 32'h1000_0000;
    localparam logic [31:0] WIN_A_HI    = 32'h1000_0100;
    localparam logic [31:0] WIN_B_HI    = 32'h1000_0200;
    localparam logic [31:0] WIN_META_HI = 32'h1000_0240;

    integer sparse_bytes [0:2];   // [0]=A [1]=B [2]=metadata
    integer dense_bytes  [0:1];   // [0]=A [1]=B
    logic prev_sparse_mem_valid, prev_dense_mem_valid;

    always @(posedge clk) begin
        if (rst) begin
            sparse_bytes[0] <= 0; sparse_bytes[1] <= 0; sparse_bytes[2] <= 0;
            dense_bytes[0]  <= 0; dense_bytes[1]  <= 0;
        end
        else begin
            if (dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.mem_req_valid &&
                dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.mem_req_ready &&
                !prev_sparse_mem_valid)
            begin
                if (dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.mem_req_addr < WIN_A_HI)
                    sparse_bytes[0] <= sparse_bytes[0] +
                        dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.mem_req_bytes;
                else if (dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.mem_req_addr < WIN_B_HI)
                    sparse_bytes[1] <= sparse_bytes[1] +
                        dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.mem_req_bytes;
                else
                    sparse_bytes[2] <= sparse_bytes[2] +
                        dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.mem_req_bytes;
            end

            if (dut.u_scheduler_engine.u_dense_subsystem.u_main_memory.mem_req_valid &&
                dut.u_scheduler_engine.u_dense_subsystem.u_main_memory.mem_req_ready &&
                !prev_dense_mem_valid)
            begin
                if (dut.u_scheduler_engine.u_dense_subsystem.u_main_memory.mem_req_addr < WIN_A_HI)
                    dense_bytes[0] <= dense_bytes[0] +
                        dut.u_scheduler_engine.u_dense_subsystem.u_main_memory.mem_req_bytes;
                else
                    dense_bytes[1] <= dense_bytes[1] +
                        dut.u_scheduler_engine.u_dense_subsystem.u_main_memory.mem_req_bytes;
            end

            prev_sparse_mem_valid <= dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.mem_req_valid &&
                                      dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.mem_req_ready;
            prev_dense_mem_valid  <= dut.u_scheduler_engine.u_dense_subsystem.u_main_memory.mem_req_valid &&
                                      dut.u_scheduler_engine.u_dense_subsystem.u_main_memory.mem_req_ready;
        end
    end

    //==========================================================================
    // Descriptor Preload Task
    //==========================================================================

    task automatic write_word(
        input logic [DESC_INDEX_WIDTH-1:0]   idx,
        input logic [WORD_COUNTER_WIDTH-1:0] word_off,
        input descriptor_mem_word_t          data
    );
        @(posedge clk);
        cpu_we          <= 1'b1;
        cpu_desc_idx    <= idx;
        cpu_word_offset <= word_off;
        cpu_wdata       <= data;
        @(posedge clk);
        cpu_we <= 1'b0;
    endtask

    task automatic load_descriptor(
        input logic [DESC_INDEX_WIDTH-1:0] idx,
        input logic [31:0] srcA_addr,
        input logic [31:0] srcB_addr,
        input logic [31:0] metadata_addr,
        input logic [31:0] dst_addr,
        input logic [15:0] rows,
        input logic [15:0] cols,
        input logic [15:0] k,
        input logic [15:0] strideA,
        input logic [15:0] strideB,
        input logic [15:0] strideC,
        input logic [7:0]  bytes_per_element,
        input logic [7:0]  flag_bits
    );
        write_word(idx, DESC_WORD_SRCA,      srcA_addr);
        write_word(idx, DESC_WORD_SRCB,      srcB_addr);
        write_word(idx, DESC_WORD_METADATA,  metadata_addr);
        write_word(idx, DESC_WORD_DST,       dst_addr);
        write_word(idx, DESC_WORD_ROWS_COLS, {rows, cols});
        write_word(idx, DESC_WORD_K_STRIDEA, {k, strideA});
        write_word(idx, DESC_WORD_STRIDEB_C, {strideB, strideC});
        write_word(idx, DESC_WORD_FLAGS,     {16'd0, bytes_per_element, flag_bits});
    endtask

    //==========================================================================
    // Side-by-Side Matrix Report
    //==========================================================================

    integer sparse_mismatches;
    integer dense_mismatches;

    task automatic print_sparse_matrix;
        integer r, c;
        string  row_ok;
        begin
            $display("");
            $display("  SPARSE 8x8  (golden | measured)                  row match");
            $display("  ---------------------------------------------------------");
            $display("  [note] read via hierarchical ref into u_sparse_compute_8x8.result,");
            $display("         not the debug_sparse_result port -- Icarus fails to");
            $display("         propagate a 2D unpacked array-of-packed port even one");
            $display("         module boundary (confirmed with an isolated repro).");
            $display("         The value is correct at every level; only the port");
            $display("         read is broken under Icarus. See prior fix notes.");
            sparse_mismatches = 0;
            for (r = 0; r < 8; r = r + 1) begin
                row_ok = "OK";
                for (c = 0; c < 8; c = c + 1) begin
                    if (dut.u_scheduler_engine.u_sparse_subsystem.u_sparse_datapath.u_sparse_compute_8x8.result[r][c] !== expected_sparse_c[r][c]) begin
                        row_ok = "MISMATCH";
                        sparse_mismatches = sparse_mismatches + 1;
                    end
                end
                $display("  row %0d  %5d %5d %5d %5d %5d %5d %5d %5d | %5d %5d %5d %5d %5d %5d %5d %5d   %s",
                    r,
                    expected_sparse_c[r][0], expected_sparse_c[r][1], expected_sparse_c[r][2], expected_sparse_c[r][3],
                    expected_sparse_c[r][4], expected_sparse_c[r][5], expected_sparse_c[r][6], expected_sparse_c[r][7],
                    dut.u_scheduler_engine.u_sparse_subsystem.u_sparse_datapath.u_sparse_compute_8x8.result[r][0],
                    dut.u_scheduler_engine.u_sparse_subsystem.u_sparse_datapath.u_sparse_compute_8x8.result[r][1],
                    dut.u_scheduler_engine.u_sparse_subsystem.u_sparse_datapath.u_sparse_compute_8x8.result[r][2],
                    dut.u_scheduler_engine.u_sparse_subsystem.u_sparse_datapath.u_sparse_compute_8x8.result[r][3],
                    dut.u_scheduler_engine.u_sparse_subsystem.u_sparse_datapath.u_sparse_compute_8x8.result[r][4],
                    dut.u_scheduler_engine.u_sparse_subsystem.u_sparse_datapath.u_sparse_compute_8x8.result[r][5],
                    dut.u_scheduler_engine.u_sparse_subsystem.u_sparse_datapath.u_sparse_compute_8x8.result[r][6],
                    dut.u_scheduler_engine.u_sparse_subsystem.u_sparse_datapath.u_sparse_compute_8x8.result[r][7],
                    row_ok
                );
            end
        end
    endtask

    task automatic print_dense_matrix;
        integer r, c;
        string  row_ok;
        begin
            $display("");
            $display("  DENSE 8x8  (golden | measured)                   row match");
            $display("  ---------------------------------------------------------");
            dense_mismatches = 0;
            for (r = 0; r < 8; r = r + 1) begin
                row_ok = "OK";
                for (c = 0; c < 8; c = c + 1) begin
                    if (measured_dense_c[r][c] !== expected_dense_c[r][c]) begin
                        row_ok = "MISMATCH";
                        dense_mismatches = dense_mismatches + 1;
                    end
                end
                $display("  row %0d  %5d %5d %5d %5d %5d %5d %5d %5d | %5d %5d %5d %5d %5d %5d %5d %5d   %s",
                    r,
                    expected_dense_c[r][0], expected_dense_c[r][1], expected_dense_c[r][2], expected_dense_c[r][3],
                    expected_dense_c[r][4], expected_dense_c[r][5], expected_dense_c[r][6], expected_dense_c[r][7],
                    measured_dense_c[r][0], measured_dense_c[r][1], measured_dense_c[r][2], measured_dense_c[r][3],
                    measured_dense_c[r][4], measured_dense_c[r][5], measured_dense_c[r][6], measured_dense_c[r][7],
                    row_ok
                );
            end
        end
    endtask

    //==========================================================================
    // Stimulus
    //==========================================================================

    //==========================================================================
    // Indexed-read sweep: exercises the exact path FMAC_READ uses
    // (result_read_index_in -> result_read_data_out), all 64 flat indices
    // (row=idx[5:3], col=idx[2:0]) against the golden matrix.
    //==========================================================================
    integer idxread_sparse_mismatches;
    integer idxread_dense_mismatches;

    task automatic sweep_indexed_read(input bit is_sparse);
        integer i, mism;
        logic signed [63:0] exp_val;
        begin
            mism = 0;
            for (i = 0; i < 64; i = i + 1) begin
                result_read_index_in = i[5:0];
                #1;
                exp_val = is_sparse ? expected_sparse_c[i[5:3]][i[2:0]]
                                    : expected_dense_c [i[5:3]][i[2:0]];
                if (result_read_data_out !== exp_val) begin
                    mism = mism + 1;
                    if (mism <= 4)
                        $display("  [FAIL] indexed read %s idx=%0d expected=%0d got=%0d",
                                 is_sparse ? "sparse" : "dense", i, exp_val, result_read_data_out);
                end
            end
            if (is_sparse) idxread_sparse_mismatches = mism;
            else           idxread_dense_mismatches  = mism;
            $display("  Indexed read (%s): %0d/64 match via result_read_data_out",
                     is_sparse ? "sparse" : "dense", 64 - mism);
        end
    endtask

    integer error_count;

    //==========================================================================
    // Sparse-vs-Dense EQUIVALENCE test support
    //
    // Same A (2:4-pruned) and same B run through BOTH paths:
    //   sparse job : compressed A + metadata + B
    //   dense  job : A expanded back to 8x8 (pruned zeros restored) + same B
    // Mathematically identical, so results must match element-for-element,
    // and both must match a golden computed HERE from the operands.
    //
    // Memory images are poked into each subsystem's private main_memory_model
    // (layout: A @ byte 0, B @ byte 256, metadata @ byte 512, 32-bit LE words)
    // after jobs 0/1 finish, so the original tests are undisturbed.
    //
    // Metadata decode (per 4-wide group, 3-bit code -> kept positions):
    //   0->(0,1) 1->(0,2) 2->(0,3) 3->(1,2) 4->(1,3)   [derived by matching
    //   the shipped image against the hand golden -- unique solution]
    //   5->(2,3)                                        [ASSUMED, unverified;
    //   never generated below]
    //==========================================================================
    integer eq_A_comp [0:31];
    integer eq_meta   [0:15];
    integer eq_B      [0:63];
    integer eq_A_exp  [0:63];
    logic signed [63:0] eq_golden     [0:63];
    logic signed [63:0] eq_sparse_res [0:63];
    logic signed [63:0] eq_dense_res  [0:63];
    integer      eq_sparse_cycles, eq_dense_cycles;
    logic [31:0] eq_sparse_macs,   eq_dense_macs;

    task automatic meta_decode(input integer m, output integer i0, output integer i1);
        begin
            case (m)
                0: begin i0 = 0; i1 = 1; end
                1: begin i0 = 0; i1 = 2; end
                2: begin i0 = 0; i1 = 3; end
                3: begin i0 = 1; i1 = 2; end
                4: begin i0 = 1; i1 = 3; end
                5: begin i0 = 2; i1 = 3; end
                default: begin i0 = 0; i1 = 1; end
            endcase
        end
    endtask

    task automatic poke_word(input bit to_sparse_mem, input integer byte_off, input logic [31:0] val);
        integer i;
        begin
            for (i = 0; i < 4; i = i + 1) begin
                if (to_sparse_mem)
                    dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.memory[byte_off + i] = val[i*8 +: 8];
                else
                    dut.u_scheduler_engine.u_dense_subsystem.u_main_memory.memory[byte_off + i]  = val[i*8 +: 8];
            end
        end
    endtask

    function automatic logic [31:0] peek_sparse_word(input integer byte_off);
        integer i;
        logic [31:0] w;
        begin
            for (i = 0; i < 4; i = i + 1)
                w[i*8 +: 8] = dut.u_scheduler_engine.u_sparse_subsystem.u_main_memory.memory[byte_off + i];
            peek_sparse_word = w;
        end
    endfunction

    // case 0: read the operands straight out of the shipped sparse image.
    // case 1: random signed operands, metadata codes 0..4 only (verified).
    task automatic eq_build_case(input integer case_id);
        integer r, c, k, g, i0, i1, v;
        logic signed [63:0] acc;
        begin
            if (case_id == 0) begin
                for (k = 0; k < 32; k = k + 1) eq_A_comp[k] = $signed(peek_sparse_word(k*4));
                for (k = 0; k < 64; k = k + 1) eq_B[k]      = $signed(peek_sparse_word(256 + k*4));
                for (k = 0; k < 16; k = k + 1) eq_meta[k]   = peek_sparse_word(512 + k*4);
            end
            else begin
                for (k = 0; k < 32; k = k + 1) eq_A_comp[k] = $urandom_range(200, 0) - 100;
                for (k = 0; k < 64; k = k + 1) eq_B[k]      = $urandom_range(100, 0) - 50;
                for (k = 0; k < 16; k = k + 1) eq_meta[k]   = $urandom_range(4, 0);
            end

            for (k = 0; k < 64; k = k + 1) eq_A_exp[k] = 0;
            for (r = 0; r < 8; r = r + 1)
                for (g = 0; g < 2; g = g + 1) begin
                    meta_decode(eq_meta[r*2 + g], i0, i1);
                    eq_A_exp[r*8 + g*4 + i0] = eq_A_comp[r*4 + g*2];
                    eq_A_exp[r*8 + g*4 + i1] = eq_A_comp[r*4 + g*2 + 1];
                end

            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1) begin
                    acc = 0;
                    for (k = 0; k < 8; k = k + 1)
                        acc = acc + $signed(eq_A_exp[r*8 + k]) * $signed(eq_B[k*8 + c]);
                    eq_golden[r*8 + c] = acc;
                end
        end
    endtask

    task automatic eq_poke_images;
        integer k;
        begin
            // sparse subsystem: compressed A, B, metadata
            for (k = 0; k < 32; k = k + 1) poke_word(1'b1, k*4,       eq_A_comp[k]);
            for (k = 0; k < 64; k = k + 1) poke_word(1'b1, 256 + k*4, eq_B[k]);
            for (k = 0; k < 16; k = k + 1) poke_word(1'b1, 512 + k*4, eq_meta[k]);
            // dense subsystem: expanded A, same B
            for (k = 0; k < 64; k = k + 1) poke_word(1'b0, k*4,       eq_A_exp[k]);
            for (k = 0; k < 64; k = k + 1) poke_word(1'b0, 256 + k*4, eq_B[k]);
        end
    endtask

    task automatic eq_dispatch(input logic [DESC_INDEX_WIDTH-1:0] idx, output integer cycles);
        time t0;
        begin
            t0 = $time;
            job_index_in <= idx;
            run <= 1'b1;
            @(posedge clk);
            run <= 1'b0;
            wait (all_done);
            cycles = ($time - t0) / CLK_PERIOD;
            if (any_error) begin
                $display("  [FAIL] accelerator_top reported any_error on job idx=%0d", idx);
                error_count = error_count + 1;
            end
            repeat (2) @(posedge clk);
        end
    endtask

    // read all 64 results back through the FMAC_READ path
    task automatic eq_capture(input bit is_sparse);
        integer i;
        begin
            for (i = 0; i < 64; i = i + 1) begin
                result_read_index_in = i[5:0];
                #1;
                if (is_sparse) eq_sparse_res[i] = result_read_data_out;
                else           eq_dense_res[i]  = result_read_data_out;
            end
        end
    endtask

    task automatic eq_run_case(input integer case_id, input string label);
        integer i, sp_bad, de_bad, x_bad, gold_bad;
        begin
            eq_build_case(case_id);
            eq_poke_images();
            repeat (2) @(posedge clk);

            eq_dispatch(2, eq_sparse_cycles);      // sparse descriptor
            eq_sparse_macs = debug_sparse_mac_count;
            eq_capture(1'b1);

            eq_dispatch(3, eq_dense_cycles);       // dense descriptor
            eq_dense_macs = debug_dense_mac_count;
            eq_capture(1'b0);

            sp_bad = 0; de_bad = 0; x_bad = 0; gold_bad = 0;
            for (i = 0; i < 64; i = i + 1) begin
                if (eq_sparse_res[i] !== eq_golden[i]) begin
                    sp_bad = sp_bad + 1;
                    if (sp_bad <= 3) $display("  [FAIL] sparse idx=%0d expected=%0d got=%0d", i, eq_golden[i], eq_sparse_res[i]);
                end
                if (eq_dense_res[i] !== eq_golden[i]) begin
                    de_bad = de_bad + 1;
                    if (de_bad <= 3) $display("  [FAIL] dense  idx=%0d expected=%0d got=%0d", i, eq_golden[i], eq_dense_res[i]);
                end
                if (eq_sparse_res[i] !== eq_dense_res[i]) begin
                    x_bad = x_bad + 1;
                    if (x_bad <= 3) $display("  [FAIL] sparse!=dense idx=%0d sparse=%0d dense=%0d", i, eq_sparse_res[i], eq_dense_res[i]);
                end
                // case 0 only: the computed golden must equal the hand-typed one
                if (case_id == 0 && eq_golden[i] !== expected_sparse_c[i/8][i%8]) gold_bad = gold_bad + 1;
            end

            $display("");
            $display("  --- EQUIVALENCE %s ---", label);
            $display("  sparse vs computed golden : %0d/64 match", 64 - sp_bad);
            $display("  dense  vs computed golden : %0d/64 match", 64 - de_bad);
            $display("  sparse vs dense           : %0d/64 identical", 64 - x_bad);
            if (case_id == 0)
                $display("  computed golden vs hand-typed golden : %0d/64 match", 64 - gold_bad);
            $display("  same operands, like-for-like:");
            $display("    latency : sparse %0d cycles | dense %0d cycles | dense/sparse = %0.2fx",
                     eq_sparse_cycles, eq_dense_cycles, (1.0 * eq_dense_cycles) / eq_sparse_cycles);
            $display("    MACs    : sparse %0d | dense %0d   (raw counter reads; expect 256 / 512)",
                     eq_sparse_macs, eq_dense_macs);

            error_count = error_count + sp_bad + de_bad + x_bad + gold_bad;
        end
    endtask
    real    sparse_latency_ns, dense_latency_ns;
    integer sparse_latency_cycles, dense_latency_cycles;
    real    dense_theoretical_macs, mac_reduction_pct;

    real    sparse_utilization_pct, dense_utilization_pct;
    integer sparse_bytes_total, dense_bytes_total;
    real    sparse_macs_per_byte, dense_macs_per_byte;
    real    a_compression_pct;
    integer sparse_transfer_cycles, sparse_compute_cycles;
    integer dense_transfer_cycles, dense_compute_cycles;
    real    metadata_overhead_pct;
    integer sparse_dispatch_cycles, dense_dispatch_cycles;
    real    sparse_throughput, dense_throughput;

    initial begin

        clk = 1'b0;
        rst = 1'b1;
        run = 1'b0;
        job_index_in = '0;
        result_read_index_in = '0;
        cpu_we = 1'b0;
        cpu_desc_idx = '0;
        cpu_word_offset = '0;
        cpu_wdata = '0;
        error_count = 0;
        job0_issue_time = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);

        $display("============================================================");
        $display("  ACCELERATOR TOP -- RESEARCH INTEGRATION RUN");
        $display("  (VERBOSE=%0d: module-internal debug traces %s)",
                  VERBOSE, VERBOSE ? "ENABLED" : "silenced");
        $display("============================================================");

        // idx, srcA, srcB, metadata, dst, rows, cols, k, strideA, strideB,
        // strideC, bytes_per_element, flag_bits
        load_descriptor(
            0, 32'h1000_0000, 32'h1000_0100, 32'h1000_0200, 32'h1000_0300,
            16'd8, 16'd8, 16'd8, 16'd32, 16'd32, 16'd32,
            8'd4, 8'b0000_0001   // FLAG_SPARSE_ENABLE
        );

        load_descriptor(
            1, 32'h1000_0000, 32'h1000_0100, 32'h0000_0000, 32'h1000_0200,
            16'd8, 16'd8, 16'd8, 16'd32, 16'd32, 16'd32,
            8'd4, 8'b0000_0000   // dense
        );

        repeat (3) @(posedge clk);

        //======================================================
        // Job 0 -- sparse (descriptor index 0)
        //
        // accelerator_top now runs exactly ONE job per run pulse and
        // returns to idle with a one-cycle all_done pulse -- it no longer
        // auto-walks both descriptors off a single run pulse. So each job
        // gets its own explicit job_index_in + run pulse + all_done wait,
        // instead of one run pulse followed by watching the index tick over.
        //======================================================
        job0_issue_time = $time;
        job_index_in <= 0;
        run <= 1'b1;
        @(posedge clk);
        run <= 1'b0;

        wait (all_done);
        job0_done_time = $time;

        if (any_error) begin
            $display("");
            $display("  [FAIL] accelerator_top reported any_error on job 0 (sparse)");
            error_count = error_count + 1;
        end

        repeat (2) @(posedge clk);

        print_sparse_matrix();
        sweep_indexed_read(1'b1);
        error_count = error_count + idxread_sparse_mismatches;

        if (debug_sparse_mac_count !== 32'd256) begin
            $display("");
            $display("  [FAIL] Sparse MAC count expected=256 got=%0d", debug_sparse_mac_count);
            error_count = error_count + sparse_mismatches + 1;
        end
        else if (sparse_mismatches != 0) begin
            error_count = error_count + sparse_mismatches;
        end

        //======================================================
        // Job 1 -- dense (descriptor index 1)
        //======================================================
        job1_issue_time = $time;
        job_index_in <= 1;
        run <= 1'b1;
        @(posedge clk);
        run <= 1'b0;

        wait (all_done);
        job1_done_time = $time;
        repeat (2) @(posedge clk);

        print_dense_matrix();
        sweep_indexed_read(1'b0);
        error_count = error_count + idxread_dense_mismatches;

        if (any_error) begin
            $display("");
            $display("  [FAIL] accelerator_top reported any_error on job 1 (dense)");
            error_count = error_count + 1;
        end
        if (dense_result_count !== 64) begin
            $display("  [FAIL] Dense results expected=64 observed=%0d", dense_result_count);
            error_count = error_count + 1;
        end
        if (dense_order_error_count !== 0) begin
            $display("  [FAIL] Dense out-of-range row/col events = %0d", dense_order_error_count);
            error_count = error_count + 1;
        end
        error_count = error_count + dense_mismatches;

        //----------------------------------------------------------------------
        // Metrics
        //----------------------------------------------------------------------

        sparse_latency_ns     = (job0_done_time - job0_issue_time) / 1.0;
        dense_latency_ns      = (job1_done_time - job1_issue_time) / 1.0;
        sparse_latency_cycles = (job0_done_time - job0_issue_time) / CLK_PERIOD;
        dense_latency_cycles  = (job1_done_time - job1_issue_time) / CLK_PERIOD;

        // Dense equivalent of an 8x8x8 tile done densely: rows*cols*k MACs.
        dense_theoretical_macs = 8.0 * 8.0 * 8.0;
        mac_reduction_pct = 100.0 *
            (dense_theoretical_macs - debug_sparse_mac_count) /
            dense_theoretical_macs;

        // (1) Utilization: MACs actually executed vs. MACs possible at
        // 1/cycle over the job's own latency.
        sparse_utilization_pct = 100.0 * debug_sparse_mac_count / sparse_latency_cycles;
        dense_utilization_pct  = 100.0 * debug_dense_mac_count  / dense_latency_cycles;

        // (2) Memory traffic, per operand, as actually DMA'd (see monitor
        // block above for how these are captured).
        sparse_bytes_total = sparse_bytes[0] + sparse_bytes[1] + sparse_bytes[2];
        dense_bytes_total  = dense_bytes[0]  + dense_bytes[1];

        // (3) Compute-to-memory ratio: MACs per byte moved.
        sparse_macs_per_byte = 1.0 * debug_sparse_mac_count / sparse_bytes_total;
        dense_macs_per_byte  = 1.0 * debug_dense_mac_count  / dense_bytes_total;

        // (4) Sparsity ratio realized: compressed A (sparse_bytes[0]) vs.
        // the SAME descriptor's dense A size, measured from job 1's own A
        // transfer (dense_bytes[0]) rather than assumed -- both jobs share
        // identical rows/cols/k/bytes_per_element in this run, so this is a
        // real cross-job measurement, not a computed constant.
        a_compression_pct = 100.0 *
            (dense_bytes[0] - sparse_bytes[0]) / dense_bytes[0];

        // (5)/(6) Phase split, in cycles.
        sparse_transfer_cycles = (sparse_transfer_end_t - sparse_transfer_start_t) / CLK_PERIOD;
        sparse_compute_cycles  = (sparse_compute_busy_end_t - sparse_compute_busy_start_t) / CLK_PERIOD;
        dense_transfer_cycles  = (dense_transfer_end_t - dense_transfer_start_t) / CLK_PERIOD;
        dense_compute_cycles   = (dense_compute_busy_end_t - dense_compute_busy_start_t) / CLK_PERIOD;

        // (7) Metadata overhead: metadata bytes as a fraction of total
        // sparse-job bytes moved (the real cost of the 2:4 encoding).
        metadata_overhead_pct = 100.0 * sparse_bytes[2] / sparse_bytes_total;

        // (8) Descriptor-to-dispatch latency: DFU fetch start to compute
        // engine actually starting, in cycles -- front-end overhead
        // separate from compute itself.
        sparse_dispatch_cycles = (job0_compute_start_time - job0_dfu_start_time) / CLK_PERIOD;
        dense_dispatch_cycles  = (job1_compute_start_time - job1_dfu_start_time) / CLK_PERIOD;

        // (9) Throughput, MACs/cycle (absolute, not normalized to a
        // theoretical peak -- same underlying numbers as utilization,
        // presented in the units a roofline plot actually wants).
        sparse_throughput = 1.0 * debug_sparse_mac_count / sparse_latency_cycles;
        dense_throughput  = 1.0 * debug_dense_mac_count  / dense_latency_cycles;

        $display("");
        $display("============================================================");
        $display("  RESEARCH METRICS");
        $display("============================================================");
        $display("");
        $display("  ---------------------------- SPARSE 8x8 -------------------");
        $display("  (1) Latency                : %0.1f ns  (%0d cycles @ %0.0f MHz)",
                  sparse_latency_ns, sparse_latency_cycles, 1000.0/CLK_PERIOD);
        $display("  (2) MAC utilization        : %0.1f%%  (%0d MACs / %0d cycles)",
                  sparse_utilization_pct, debug_sparse_mac_count, sparse_latency_cycles);
        $display("  (3) Memory traffic         : A=%0dB  B=%0dB  meta=%0dB  total=%0dB",
                  sparse_bytes[0], sparse_bytes[1], sparse_bytes[2], sparse_bytes_total);
        $display("  (4) Compute/memory ratio   : %0.3f MACs/byte", sparse_macs_per_byte);
        $display("  (5) A compression realized : %0.1f%%  (dense A=%0dB, sparse A=%0dB)",
                  a_compression_pct, dense_bytes[0], sparse_bytes[0]);
        $display("  (6) Transfer/compute split : %0d cycles transfer, %0d cycles compute",
                  sparse_transfer_cycles, sparse_compute_cycles);
        $display("  (7) Metadata overhead      : %0.1f%% of total bytes moved (%0dB of %0dB)",
                  metadata_overhead_pct, sparse_bytes[2], sparse_bytes_total);
        $display("  (8) Descriptor->dispatch   : %0d cycles (fetch start to compute start)",
                  sparse_dispatch_cycles);
        $display("  (9) Throughput             : %0.3f MACs/cycle", sparse_throughput);
        $display(" (10) Correctness            : %0d/64 elements correct, MAC count %0d (expect 256)",
                  64 - sparse_mismatches, debug_sparse_mac_count);
        $display("      Dense-equivalent MACs for this tile : %0.0f  (realized reduction %0.1f%%)",
                  dense_theoretical_macs, mac_reduction_pct);
        $display("");
        $display("  ---------------------------- DENSE 8x8 ---------------------");
        $display("  (1) Latency                : %0.1f ns  (%0d cycles @ %0.0f MHz)",
                  dense_latency_ns, dense_latency_cycles, 1000.0/CLK_PERIOD);
        $display("  (2) MAC utilization        : %0.1f%%  (%0d MACs / %0d cycles)",
                  dense_utilization_pct, debug_dense_mac_count, dense_latency_cycles);
        $display("  (3) Memory traffic         : A=%0dB  B=%0dB  total=%0dB",
                  dense_bytes[0], dense_bytes[1], dense_bytes_total);
        $display("  (4) Compute/memory ratio   : %0.3f MACs/byte", dense_macs_per_byte);
        $display("  (6) Transfer/compute split : %0d cycles transfer, %0d cycles compute",
                  dense_transfer_cycles, dense_compute_cycles);
        $display("  (8) Descriptor->dispatch   : %0d cycles (fetch start to compute start)",
                  dense_dispatch_cycles);
        $display("  (9) Throughput             : %0.3f MACs/cycle", dense_throughput);
        $display(" (10) Correctness            : %0d/64 elements correct, MAC count %0d (expect 512)",
                  64 - dense_mismatches, debug_dense_mac_count);
        $display("");
        $display("  [note] (5) A-compression and (7) metadata overhead are");
        $display("         sparse-specific -- dense has no compressed operand");
        $display("         and no metadata stream, so both are structurally N/A");
        $display("         for the dense job rather than omitted by oversight.");
        $display("");
        $display("  Total run time              : %0.1f ns", $time / 1.0);
        $display("============================================================");


        //======================================================
        // Sparse-vs-Dense EQUIVALENCE (same operands, both paths)
        // jobs 2 (sparse) / 3 (dense) reuse the job 0 / job 1 addressing.
        //======================================================
        $display("");
        $display("============================================================");
        $display("  SPARSE vs DENSE EQUIVALENCE (same A, same B)");
        $display("============================================================");

        load_descriptor(
            2, 32'h1000_0000, 32'h1000_0100, 32'h1000_0200, 32'h1000_0300,
            16'd8, 16'd8, 16'd8, 16'd32, 16'd32, 16'd32,
            8'd4, 8'b0000_0001   // sparse
        );
        load_descriptor(
            3, 32'h1000_0000, 32'h1000_0100, 32'h0000_0000, 32'h1000_0200,
            16'd8, 16'd8, 16'd8, 16'd32, 16'd32, 16'd32,
            8'd4, 8'b0000_0000   // dense
        );
        repeat (3) @(posedge clk);

        eq_run_case(0, "case 0: shipped sparse_data_memory.mem operands");
        eq_run_case(1, "case 1: random signed A/B, metadata codes 0..4");

        $display("============================================================");

        if (error_count == 0)
            $display("  ACCELERATOR TOP RESEARCH RUN : PASS (sparse + dense + equivalence verified)");
        else
            $display("  ACCELERATOR TOP RESEARCH RUN : FAIL (%0d total mismatches/errors)", error_count);
        $display("============================================================");

        $finish;
    end

    //==========================================================================
    // Safety Timeout
    //==========================================================================

    initial begin
        #800000;
        $display("[FAIL] TIMEOUT -- accelerator_top never reached all_done");
        $finish;
    end

endmodule