//==============================================================================
// Testbench : scratchpad_sparse_tb
//
// Purpose:
//   Verify the new sparse compute access paths without modifying the
//   underlying scratchpad_bank implementation.
//
// Checks:
//
//   1. DMA writes to Bank A/B/C
//   2. Sparse A read
//   3. Sparse B read
//   4. Sparse metadata read
//   5. Simultaneous sparse A/B/metadata reads
//   6. Existing dense compute path
//==============================================================================

`timescale 1ns/1ps

module scratchpad_sparse_tb;

    localparam DATA_WIDTH = 32;
    localparam MATRIX_DIM = 8;
    localparam DEPTH      = 64;
    localparam ADDR_WIDTH = 6;

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
    // DMA Interface
    //==========================================================================

    logic [1:0] dma_bank_sel;
    logic       dma_en;
    logic       dma_we;
    logic [ADDR_WIDTH-1:0] dma_addr;
    logic [DATA_WIDTH-1:0] dma_wdata;
    logic [DATA_WIDTH-1:0] dma_rdata;

    //==========================================================================
    // Existing Dense Compute Interface
    //==========================================================================

    logic [1:0] compute_bank_sel;
    logic       compute_en;
    logic       compute_we;
    logic [ADDR_WIDTH-1:0] compute_addr;
    logic [DATA_WIDTH-1:0] compute_wdata;
    logic [DATA_WIDTH-1:0] compute_rdata;

    //==========================================================================
    // Sparse A
    //==========================================================================

    logic sparse_a_en;
    logic sparse_a_we;
    logic [ADDR_WIDTH-1:0] sparse_a_addr;
    logic [DATA_WIDTH-1:0] sparse_a_wdata;
    logic [DATA_WIDTH-1:0] sparse_a_rdata;

    //==========================================================================
    // Sparse B
    //==========================================================================

    logic sparse_b_en;
    logic sparse_b_we;
    logic [ADDR_WIDTH-1:0] sparse_b_addr;
    logic [DATA_WIDTH-1:0] sparse_b_wdata;
    logic [DATA_WIDTH-1:0] sparse_b_rdata;

    //==========================================================================
    // Sparse Metadata
    //==========================================================================

    logic sparse_metadata_en;
    logic sparse_metadata_we;
    logic [ADDR_WIDTH-1:0] sparse_metadata_addr;
    logic [DATA_WIDTH-1:0] sparse_metadata_wdata;
    logic [DATA_WIDTH-1:0] sparse_metadata_rdata;

    //==========================================================================
    // DUT
    //==========================================================================

    scratchpad #(

        .DATA_WIDTH (DATA_WIDTH),
        .MATRIX_DIM (MATRIX_DIM),
        .DEPTH      (DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH)

    ) dut (

        .clk (clk),
        .rst (rst),

        // DMA
        .dma_bank_sel (dma_bank_sel),
        .dma_en       (dma_en),
        .dma_we       (dma_we),
        .dma_addr     (dma_addr),
        .dma_wdata    (dma_wdata),
        .dma_rdata    (dma_rdata),

        // Dense compute
        .compute_bank_sel (compute_bank_sel),
        .compute_en       (compute_en),
        .compute_we       (compute_we),
        .compute_addr     (compute_addr),
        .compute_wdata    (compute_wdata),
        .compute_rdata    (compute_rdata),

        // Sparse A
        .sparse_a_en       (sparse_a_en),
        .sparse_a_we       (sparse_a_we),
        .sparse_a_addr     (sparse_a_addr),
        .sparse_a_wdata    (sparse_a_wdata),
        .sparse_a_rdata    (sparse_a_rdata),

        // Sparse B
        .sparse_b_en       (sparse_b_en),
        .sparse_b_we       (sparse_b_we),
        .sparse_b_addr     (sparse_b_addr),
        .sparse_b_wdata    (sparse_b_wdata),
        .sparse_b_rdata    (sparse_b_rdata),

        // Sparse metadata
        .sparse_metadata_en
            (sparse_metadata_en),

        .sparse_metadata_we
            (sparse_metadata_we),

        .sparse_metadata_addr
            (sparse_metadata_addr),

        .sparse_metadata_wdata
            (sparse_metadata_wdata),

        .sparse_metadata_rdata
            (sparse_metadata_rdata)

    );

    //==========================================================================
    // DMA Write Task
    //==========================================================================

    task automatic dma_write;

        input [1:0] bank;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;

        begin

            @(negedge clk);

            dma_bank_sel = bank;
            dma_addr     = addr;
            dma_wdata    = data;
            dma_we       = 1'b1;
            dma_en       = 1'b1;

            @(negedge clk);

            dma_en = 1'b0;
            dma_we = 1'b0;

        end

    endtask

    //==========================================================================
    // Sparse Read
    //
    // scratchpad_bank has two registered read stages.
    //
    // Therefore:
    //
    //   cycle N     -> issue read
    //   cycle N + 1 -> stage 1
    //   cycle N + 2 -> stage 2 / visible output
    //==========================================================================

    task automatic sparse_read_all;

        input [ADDR_WIDTH-1:0] addr_a;
        input [ADDR_WIDTH-1:0] addr_b;
        input [ADDR_WIDTH-1:0] addr_metadata;

        begin

            @(negedge clk);

            sparse_a_addr       = addr_a;
            sparse_b_addr       = addr_b;
            sparse_metadata_addr = addr_metadata;

            sparse_a_en        = 1'b1;
            sparse_b_en        = 1'b1;
            sparse_metadata_en = 1'b1;

            @(negedge clk);

            sparse_a_en        = 1'b0;
            sparse_b_en        = 1'b0;
            sparse_metadata_en = 1'b0;

            @(negedge clk);

        end

    endtask

    //==========================================================================
    // Test
    //==========================================================================

    initial begin

        //---------------------------------------------------------------------- 
        // Defaults
        //----------------------------------------------------------------------

        rst = 1'b1;

        dma_bank_sel = '0;
        dma_en       = 1'b0;
        dma_we       = 1'b0;
        dma_addr     = '0;
        dma_wdata    = '0;

        compute_bank_sel = '0;
        compute_en       = 1'b0;
        compute_we       = 1'b0;
        compute_addr     = '0;
        compute_wdata    = '0;

        sparse_a_en   = 1'b0;
        sparse_a_we   = 1'b0;
        sparse_a_addr = '0;
        sparse_a_wdata = '0;

        sparse_b_en   = 1'b0;
        sparse_b_we   = 1'b0;
        sparse_b_addr = '0;
        sparse_b_wdata = '0;

        sparse_metadata_en    = 1'b0;
        sparse_metadata_we    = 1'b0;
        sparse_metadata_addr  = '0;
        sparse_metadata_wdata = '0;

        //---------------------------------------------------------------------- 
        // Reset
        //----------------------------------------------------------------------

        repeat (3)
            @(posedge clk);

        rst = 1'b0;

        $display("");
        $display("==============================================");
        $display("SCRATCHPAD SPARSE TEST");
        $display("==============================================");

        //---------------------------------------------------------------------- 
        // Populate Bank A
        //----------------------------------------------------------------------

        dma_write(
            2'b00,
            6'd0,
            32'hAAAA_0001
        );

        dma_write(
            2'b00,
            6'd1,
            32'hAAAA_0002
        );

        //---------------------------------------------------------------------- 
        // Populate Bank B
        //----------------------------------------------------------------------

        dma_write(
            2'b01,
            6'd4,
            32'hBBBB_0001
        );

        dma_write(
            2'b01,
            6'd5,
            32'hBBBB_0002
        );

        //---------------------------------------------------------------------- 
        // Populate Bank C with metadata
        //----------------------------------------------------------------------

        dma_write(
            2'b10,
            6'd8,
            32'h0000_0001
        );

        //---------------------------------------------------------------------- 
        // Sparse simultaneous read
        //----------------------------------------------------------------------

        sparse_read_all(
            6'd0,
            6'd4,
            6'd8
        );

        $display("----------------------------------------------");
        $display("Sparse simultaneous read");
        $display("----------------------------------------------");

        $display("Sparse A       : %h", sparse_a_rdata);
        $display("Sparse B       : %h", sparse_b_rdata);
        $display("Sparse Metadata: %h", sparse_metadata_rdata);

        //---------------------------------------------------------------------- 
        // Checks
        //----------------------------------------------------------------------

        if (sparse_a_rdata !== 32'hAAAA_0001) begin

            $display("ERROR: Sparse A read mismatch");

        end
        else begin

            $display("PASS: Sparse A read");

        end

        if (sparse_b_rdata !== 32'hBBBB_0001) begin

            $display("ERROR: Sparse B read mismatch");

        end
        else begin

            $display("PASS: Sparse B read");

        end

        if (sparse_metadata_rdata !== 32'h0000_0001) begin

            $display("ERROR: Sparse metadata read mismatch");

        end
        else begin

            $display("PASS: Sparse metadata read");

        end

        //---------------------------------------------------------------------- 
        // Verify a second simultaneous read
        //----------------------------------------------------------------------

        sparse_read_all(
            6'd1,
            6'd5,
            6'd8
        );

        $display("----------------------------------------------");
        $display("Second sparse read");
        $display("----------------------------------------------");

        $display("Sparse A       : %h", sparse_a_rdata);
        $display("Sparse B       : %h", sparse_b_rdata);
        $display("Sparse Metadata: %h", sparse_metadata_rdata);

        if (sparse_a_rdata !== 32'hAAAA_0002)
            $display("ERROR: Second Sparse A read mismatch");
        else
            $display("PASS: Second Sparse A read");

        if (sparse_b_rdata !== 32'hBBBB_0002)
            $display("ERROR: Second Sparse B read mismatch");
        else
            $display("PASS: Second Sparse B read");

        if (sparse_metadata_rdata !== 32'h0000_0001)
            $display("ERROR: Second metadata read mismatch");
        else
            $display("PASS: Second metadata read");

        //---------------------------------------------------------------------- 
        // End
        //----------------------------------------------------------------------

        $display("");
        $display("==============================================");
        $display("SCRATCHPAD SPARSE TEST COMPLETE");
        $display("==============================================");

        $finish;

    end

endmodule