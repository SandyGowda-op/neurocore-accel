//==============================================================================
// multijob_tb : step 3 -- many DIFFERENT jobs through descriptor-driven addressing.
//   Descriptor j (sparse) and 64+j (dense) point at window w(j) of a multi-job
//   memory image (base 0x1000_0000 + w*0x400). Default w(j) = N-1-j (reversal),
//   so descriptor index != memory window: a model that ignores descriptor
//   addresses (old fixed-window memory) returns job-0 data for every job -> FAIL.
//   +N=<jobs, default 32, max 64>   +IDENT (use w(j)=j instead of reversal)
// Results are read through result_read_index_in (the FMAC_READ path).
// Gold: gold_multi.mem (from gen_multijob.py), 64 x 64-bit per window.
//==============================================================================
`timescale 1ns/1ps
import descriptor_pkg::*;
import dma_pkg::*;

module multijob_tb;
    localparam time CLK_PERIOD = 10ns;
    logic clk = 1'b0, rst = 1'b1;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic run = 1'b0;
    logic [DESC_INDEX_WIDTH-1:0] job_index_in = '0;
    logic [5:0] result_read_index_in = '0;
    logic signed [63:0] result_read_data_out;
    logic all_done, any_error;
    logic cpu_we = 1'b0;
    logic [DESC_INDEX_WIDTH-1:0] cpu_desc_idx = '0;
    logic [WORD_COUNTER_WIDTH-1:0] cpu_word_offset = '0;
    descriptor_mem_word_t cpu_wdata = '0;

    logic dd_valid; logic [15:0] dd_row, dd_col; logic signed [63:0] dd_data; logic [31:0] dd_mac;
    logic signed [63:0] ds_result [0:7][0:7]; logic [31:0] ds_mac;
    logic [DESC_INDEX_WIDTH-1:0] cur_job; job_status_t jstat;

    accelerator_top #(.NUM_JOBS(2), .VERBOSE(1'b0)) dut (
        .clk(clk), .rst(rst), .run(run), .job_index_in(job_index_in),
        .all_done(all_done), .any_error(any_error),
        .cpu_we(cpu_we), .cpu_desc_idx(cpu_desc_idx),
        .cpu_word_offset(cpu_word_offset), .cpu_wdata(cpu_wdata),
        .debug_dense_result_valid(dd_valid), .debug_dense_result_row(dd_row),
        .debug_dense_result_col(dd_col), .debug_dense_result_data(dd_data),
        .debug_dense_mac_count(dd_mac),
        .debug_sparse_result(ds_result), .debug_sparse_mac_count(ds_mac),
        .result_read_index_in(result_read_index_in),
        .result_read_data_out(result_read_data_out),
        .debug_current_job_index(cur_job), .debug_job_status(jstat));

    reg signed [63:0] gold [0:64*64-1];
    integer n_jobs, errors, i, j;
    integer cyc_sp, cyc_de, t_cyc;
    bit ident;

    task automatic write_word(input logic [DESC_INDEX_WIDTH-1:0] idx,
                              input logic [WORD_COUNTER_WIDTH-1:0] off,
                              input descriptor_mem_word_t data);
        @(posedge clk); cpu_we <= 1'b1; cpu_desc_idx <= idx; cpu_word_offset <= off; cpu_wdata <= data;
        @(posedge clk); cpu_we <= 1'b0;
    endtask

    task automatic load_desc(input logic [DESC_INDEX_WIDTH-1:0] idx,
                             input logic [31:0] base, input bit sparse);
        begin
            write_word(idx, DESC_WORD_SRCA,     base);
            write_word(idx, DESC_WORD_SRCB,     base + 32'h100);
            write_word(idx, DESC_WORD_METADATA, sparse ? base + 32'h200 : 32'h0);
            write_word(idx, DESC_WORD_DST,      base + 32'h300);
            write_word(idx, DESC_WORD_ROWS_COLS, {16'd8, 16'd8});
            write_word(idx, DESC_WORD_K_STRIDEA, {16'd8, 16'd32});
            write_word(idx, DESC_WORD_STRIDEB_C, {16'd32, 16'd32});
            write_word(idx, DESC_WORD_FLAGS,     {16'd0, 8'd4, 7'd0, sparse});
        end
    endtask

    function automatic integer win(input integer jj);
        win = ident ? jj : (n_jobs - 1 - jj);
    endfunction

    task automatic run_and_check(input integer didx, input integer w, input bit sparse,
                                 output integer cycles);
        integer k, mism; time t0;
        begin
            t0 = $time;
            job_index_in <= didx[DESC_INDEX_WIDTH-1:0]; run <= 1'b1;
            @(posedge clk); run <= 1'b0;
            wait (all_done);
            cycles = ($time - t0) / CLK_PERIOD;
            if (any_error) begin
                $display("  [FAIL] any_error, desc %0d", didx); errors = errors + 1;
            end
            repeat (2) @(posedge clk);
            mism = 0;
            for (k = 0; k < 64; k = k + 1) begin
                result_read_index_in = k[5:0]; #1;
                if (result_read_data_out !== gold[w*64 + k]) begin
                    mism = mism + 1;
                    if (mism <= 2)
                        $display("  [FAIL] %s desc %0d win %0d C[%0d] exp=%0d got=%0d",
                                 sparse ? "sparse" : "dense ", didx, w, k,
                                 gold[w*64+k], result_read_data_out);
                end
            end
            errors = errors + mism;
        end
    endtask

    initial begin
        if (!$value$plusargs("N=%d", n_jobs)) n_jobs = 32;
        ident = $test$plusargs("IDENT");
        errors = 0;
        $readmemh("gold_multi.mem", gold);
        repeat (5) @(posedge clk); rst = 1'b0; repeat (3) @(posedge clk);
        $display("MULTIJOB: N=%0d jobs x {sparse,dense}, mapping=%s", n_jobs,
                 ident ? "identity" : "reversed (desc j -> window N-1-j)");
        for (j = 0; j < n_jobs; j = j + 1) begin
            load_desc(j[DESC_INDEX_WIDTH-1:0],      32'h1000_0000 + win(j)*32'h400, 1'b1);
            load_desc((64+j),                        32'h1000_0000 + win(j)*32'h400, 1'b0);
        end
        repeat (3) @(posedge clk);
        // alternate sparse/dense so consecutive jobs differ in BOTH data and path
        for (j = 0; j < n_jobs; j = j + 1) begin
            run_and_check(j,    win(j), 1'b1, cyc_sp);
            run_and_check(64+j, win(j), 1'b0, cyc_de);
            if (j == 0 || j == n_jobs-1)
                $display("  job %0d (win %0d): sparse %0d cyc, dense %0d cyc", j, win(j), cyc_sp, cyc_de);
        end
        $display("MULTIJOB: %0d jobs checked, %0d element/ctrl errors", 2*n_jobs, errors);
        if (errors == 0) $display("MULTIJOB: PASS"); else $display("MULTIJOB: FAIL");
        $finish;
    end

    initial begin #(CLK_PERIOD * 4000000); $display("MULTIJOB: TIMEOUT"); $finish; end
endmodule