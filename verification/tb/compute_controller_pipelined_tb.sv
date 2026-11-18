//==============================================================================
// compute_controller_pipelined_tb
//   Runs the ORIGINAL compute_controller and the PIPELINED one side by side on the
//   same random 8x8x8 matrices (each with its own real scratchpad_bank A/B pair),
//   checks both against a golden model, and reports cycle counts.
//   Plusargs:  +SEEDS=<n> (default 50)   +WIDE=1 (full 32-bit operand range; default 16-bit)
//==============================================================================
`timescale 1ns/1ps
module compute_controller_pipelined_tb;
    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    // shared DMA write port (loads both bank pairs identically)
    logic        dma_en = 1'b0;
    logic [5:0]  dma_addr = 6'd0;
    logic [31:0] dma_wd_a = 32'd0, dma_wd_b = 32'd0;

    // ---------------- original controller ----------------
    logic start0 = 1'b0, busy0, done0, a_en0, b_en0, rv0;
    logic [5:0] a_addr0, b_addr0;
    logic [31:0] a_rd0, b_rd0, cyc0, ar0, br0, mc0, oc0;
    logic [15:0] rr0, rc0;
    logic signed [63:0] rd0;
    scratchpad_bank #(.DATA_WIDTH(32), .MATRIX_DIM(8)) bank_a0 (.clk(clk), .rst(rst),
        .dma_en(dma_en), .dma_we(1'b1), .dma_addr(dma_addr), .dma_wdata(dma_wd_a), .dma_rdata(),
        .compute_en(a_en0), .compute_we(1'b0), .compute_addr(a_addr0), .compute_wdata(32'd0), .compute_rdata(a_rd0));
    scratchpad_bank #(.DATA_WIDTH(32), .MATRIX_DIM(8)) bank_b0 (.clk(clk), .rst(rst),
        .dma_en(dma_en), .dma_we(1'b1), .dma_addr(dma_addr), .dma_wdata(dma_wd_b), .dma_rdata(),
        .compute_en(b_en0), .compute_we(1'b0), .compute_addr(b_addr0), .compute_wdata(32'd0), .compute_rdata(b_rd0));
    compute_controller #(.DATA_WIDTH(32), .ACC_WIDTH(64), .ADDR_WIDTH(6)) ctrl0 (
        .clk(clk), .rst(rst), .start(start0),
        .base_addr_a(6'd0), .base_addr_b(6'd0), .stride_a(16'd8), .stride_b(16'd8),
        .rows(16'd8), .cols(16'd8), .k_size(16'd8),
        .busy(busy0), .done(done0),
        .spad_a_en(a_en0), .spad_a_addr(a_addr0), .spad_a_rdata(a_rd0),
        .spad_b_en(b_en0), .spad_b_addr(b_addr0), .spad_b_rdata(b_rd0),
        .result_valid(rv0), .result_row(rr0), .result_col(rc0), .result_data(rd0),
        .cycle_count(cyc0), .a_read_count(ar0), .b_read_count(br0), .mac_count(mc0), .output_count(oc0));

    // ---------------- pipelined controller ----------------
    logic start1 = 1'b0, busy1, done1, a_en1, b_en1, rv1;
    logic [5:0] a_addr1, b_addr1;
    logic [31:0] a_rd1, b_rd1, cyc1, ar1, br1, mc1, oc1;
    logic [15:0] rr1, rc1;
    logic signed [63:0] rd1;
    scratchpad_bank #(.DATA_WIDTH(32), .MATRIX_DIM(8)) bank_a1 (.clk(clk), .rst(rst),
        .dma_en(dma_en), .dma_we(1'b1), .dma_addr(dma_addr), .dma_wdata(dma_wd_a), .dma_rdata(),
        .compute_en(a_en1), .compute_we(1'b0), .compute_addr(a_addr1), .compute_wdata(32'd0), .compute_rdata(a_rd1));
    scratchpad_bank #(.DATA_WIDTH(32), .MATRIX_DIM(8)) bank_b1 (.clk(clk), .rst(rst),
        .dma_en(dma_en), .dma_we(1'b1), .dma_addr(dma_addr), .dma_wdata(dma_wd_b), .dma_rdata(),
        .compute_en(b_en1), .compute_we(1'b0), .compute_addr(b_addr1), .compute_wdata(32'd0), .compute_rdata(b_rd1));
    compute_controller_pipelined #(.DATA_WIDTH(32), .ACC_WIDTH(64), .ADDR_WIDTH(6)) ctrl1 (
        .clk(clk), .rst(rst), .start(start1),
        .base_addr_a(6'd0), .base_addr_b(6'd0), .stride_a(16'd8), .stride_b(16'd8),
        .rows(16'd8), .cols(16'd8), .k_size(16'd8),
        .busy(busy1), .done(done1),
        .spad_a_en(a_en1), .spad_a_addr(a_addr1), .spad_a_rdata(a_rd1),
        .spad_b_en(b_en1), .spad_b_addr(b_addr1), .spad_b_rdata(b_rd1),
        .result_valid(rv1), .result_row(rr1), .result_col(rc1), .result_data(rd1),
        .cycle_count(cyc1), .a_read_count(ar1), .b_read_count(br1), .mac_count(mc1), .output_count(oc1));

    // ---------------- result capture / timing ----------------
    logic signed [63:0] r0 [0:63];
    logic signed [63:0] r1 [0:63];
    integer cyc = 0, t_start = 0, t_done0 = 0, t_done1 = 0;
    logic seen0 = 1'b0, seen1 = 1'b0;
    integer n_res0 = 0, n_res1 = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (rv0) begin r0[rr0*8 + rc0] <= rd0; n_res0 <= n_res0 + 1; end
        if (rv1) begin r1[rr1*8 + rc1] <= rd1; n_res1 <= n_res1 + 1; end
        if (done0) begin seen0 <= 1'b1; t_done0 <= cyc; end
        if (done1) begin seen1 <= 1'b1; t_done1 <= cyc; end
    end

    // ---------------- stimulus ----------------
    logic signed [31:0] A [0:63];
    logic signed [31:0] B [0:63];
    logic signed [63:0] gold [0:63];
    integer nseeds, wide, s, idx, i, j, k, errs, seedv, wait_c, first_cycles_printed;
    integer cyc_o, cyc_n;
    logic signed [63:0] acc;
    logic signed [63:0] pa, pb;

    function automatic logic signed [31:0] rnd(input integer w);
        integer r;
        begin
            r = $random(seedv);
            if (w) rnd = r;
            else   rnd = $signed(r[15:0]);
        end
    endfunction

    initial begin
        if (!$value$plusargs("SEEDS=%d", nseeds)) nseeds = 50;
        if (!$value$plusargs("WIDE=%d", wide))   wide = 0;
        errs = 0; seedv = 12345; first_cycles_printed = 0;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        for (s = 0; s < nseeds; s = s + 1) begin
            for (idx = 0; idx < 64; idx = idx + 1) begin
                A[idx] = rnd(wide);  B[idx] = rnd(wide);
                if (s % 7 == 3 && (idx % 5 == 0)) A[idx] = 32'sd0;     // zeros mixed in
                r0[idx] = 64'sh5A5A5A5A5A5A5A5A; r1[idx] = 64'sh5A5A5A5A5A5A5A5A;
            end
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    acc = 64'sd0;
                    for (k = 0; k < 8; k = k + 1) begin
                        pa = A[i*8+k]; pb = B[k*8+j];
                        acc = acc + pa * pb;
                    end
                    gold[i*8+j] = acc;
                end
            // load both bank pairs through the DMA port
            for (idx = 0; idx < 64; idx = idx + 1) begin
                @(posedge clk);
                dma_en <= 1'b1; dma_addr <= idx[5:0]; dma_wd_a <= A[idx]; dma_wd_b <= B[idx];
            end
            @(posedge clk); dma_en <= 1'b0;
            repeat (4) @(posedge clk);
            // start both controllers on the same cycle
            n_res0 = 0; n_res1 = 0; seen0 = 1'b0; seen1 = 1'b0;
            @(posedge clk); start0 <= 1'b1; start1 <= 1'b1; t_start = cyc + 1;
            @(posedge clk); start0 <= 1'b0; start1 <= 1'b0;
            wait_c = 0;
            while (!(seen0 && seen1) && wait_c < 20000) begin @(posedge clk); wait_c = wait_c + 1; end
            repeat (6) @(posedge clk);
            if (!(seen0 && seen1)) begin
                $display("  FAIL seed %0d: TIMEOUT (done0=%0d done1=%0d)", s, seen0, seen1); errs = errs + 1;
            end else begin
                cyc_o = t_done0 - t_start; cyc_n = t_done1 - t_start;
                if (!first_cycles_printed) begin
                    $display("==== cycles (start->done): original=%0d pipelined=%0d  | mac_count %0d/%0d outputs %0d/%0d ====",
                             cyc_o, cyc_n, mc0, mc1, oc0, oc1);
                    first_cycles_printed = 1;
                end
                for (idx = 0; idx < 64; idx = idx + 1) begin
                    if (r0[idx] !== gold[idx]) begin
                        errs = errs + 1;
                        if (errs < 10) $display("  FAIL seed %0d ORIGINAL  C[%0d] got %0d exp %0d", s, idx, r0[idx], gold[idx]);
                    end
                    if (r1[idx] !== gold[idx]) begin
                        errs = errs + 1;
                        if (errs < 10) $display("  FAIL seed %0d PIPELINED C[%0d] got %0d exp %0d", s, idx, r1[idx], gold[idx]);
                    end
                end
                if (n_res1 != 64 || n_res0 != 64) begin
                    errs = errs + 1;
                    $display("  FAIL seed %0d result count orig=%0d pipelined=%0d (expected 64)", s, n_res0, n_res1);
                end
            end
        end
        $display("==== COMPUTE CONTROLLER (%0d seeds, wide=%0d): %0s (%0d errors) ====",
                 nseeds, wide, (errs == 0) ? "PASS" : "FAIL", errs);
        $finish;
    end
endmodule