`timescale 1ns/1ps

import tile_pkg::*;

module sparse_transfer_engine_tb;

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
    // Dense Request Interface
    //
    // Kept inactive in this testbench.
    // We are testing only the sparse path.
    //==========================================================================

    tile_request_t tile_request;
    logic tile_request_ready;

    //==========================================================================
    // Sparse Request Interface
    //==========================================================================

    sparse_tile_request_t sparse_tile_request;
    logic sparse_tile_request_ready;

    //==========================================================================
    // Transfer Engine Status
    //==========================================================================

    logic busy;
    logic done;
    logic error;

    //==========================================================================
    // Memory Interface
    //==========================================================================

    logic        mem_valid;
    logic        mem_ready;
    logic [31:0] mem_addr;
    logic [31:0] mem_bytes;

    logic [63:0] mem_rdata;
    logic        mem_rvalid;
    logic        mem_rlast;
    logic        mem_rready;

    //==========================================================================
    // Scratchpad Interface
    //==========================================================================

    logic        spad_write_enable;
    logic [3:0]  spad_bank;
    logic [31:0] spad_address;
    logic [63:0] spad_write_data;
    logic        spad_ready;

    //==========================================================================
    // DUT
    //==========================================================================

    transfer_engine dut
    (
        .clk                       (clk),
        .rst                       (rst),

        // Dense request
        .tile_request              (tile_request),
        .tile_request_ready       (tile_request_ready),

        // Sparse request
        .sparse_tile_request       (sparse_tile_request),
        .sparse_tile_request_ready(sparse_tile_request_ready),

        // Status
        .busy                      (busy),
        .done                      (done),
        .error                     (error),

        // Memory
        .mem_valid                 (mem_valid),
        .mem_ready                 (mem_ready),
        .mem_addr                  (mem_addr),
        .mem_bytes                 (mem_bytes),

        .mem_rdata                 (mem_rdata),
        .mem_rvalid                (mem_rvalid),
        .mem_rlast                 (mem_rlast),
        .mem_rready                (mem_rready),

        // Scratchpad
        .spad_write_enable         (spad_write_enable),
        .spad_bank                  (spad_bank),
        .spad_address               (spad_address),
        .spad_write_data            (spad_write_data),
        .spad_ready                 (spad_ready)
    );

    //==========================================================================
    // Memory Model
    //
    // We intentionally keep this model simple.
    //
    // For every accepted memory request:
    //
    //     mem_valid && mem_ready
    //
    // the model returns 64-bit beats until the requested byte count
    // has been transferred.
    //==========================================================================

    integer memory_request_count;
    integer memory_beat_count;

    integer current_memory_beats;
    integer memory_beats_remaining;

    logic memory_active;

    always_ff @(posedge clk) begin

        if (rst) begin

            mem_rvalid <= 1'b0;
            mem_rlast  <= 1'b0;
            mem_rdata  <= 64'd0;

            memory_request_count <= 0;
            memory_beat_count    <= 0;

            current_memory_beats <= 0;
            memory_beats_remaining <= 0;
            memory_active <= 1'b0;

        end
        else begin

            mem_rvalid <= 1'b0;
            mem_rlast  <= 1'b0;

            //------------------------------------------------------------------
            // Accept new memory request
            //------------------------------------------------------------------

            if (mem_valid && mem_ready && !memory_active) begin

                memory_request_count <=
                    memory_request_count + 1;

                current_memory_beats =
                    (mem_bytes + 7) / 8;

                memory_beats_remaining <=
                    (mem_bytes + 7) / 8;

                memory_active <= 1'b1;

                $display(
                    "[MEM] request addr=%h bytes=%0d beats=%0d",
                    mem_addr,
                    mem_bytes,
                    (mem_bytes + 7) / 8
                );

            end

            //------------------------------------------------------------------
            // Generate memory response beats
            //------------------------------------------------------------------

            else if (memory_active && mem_rready) begin

                mem_rvalid <= 1'b1;

                mem_rdata <=
                    64'hA5A5_0000_0000_0000 |
                    memory_beat_count;

                memory_beat_count <=
                    memory_beat_count + 1;

                if (memory_beats_remaining == 1) begin

                    mem_rlast <= 1'b1;

                    memory_beats_remaining <= 0;
                    memory_active <= 1'b0;

                end
                else begin

                    memory_beats_remaining <=
                        memory_beats_remaining - 1;
                end

            end
        end
    end

    //==========================================================================
    // Memory / Scratchpad Defaults
    //==========================================================================

    initial begin
        mem_ready = 1'b1;
        mem_rready = 1'b1;
        spad_ready = 1'b1;
    end

    //==========================================================================
    // Helper: Clear Requests
    //==========================================================================

    task automatic clear_requests;
    begin
        tile_request = '0;
        sparse_tile_request = '0;
    end
    endtask

    //==========================================================================
    // Helper: Start Sparse Transfer
    //==========================================================================

    task automatic start_sparse_transfer;

    begin

        @(negedge clk);

        sparse_tile_request.valid = 1'b1;

        @(negedge clk);

        sparse_tile_request.valid = 1'b0;

    end

    endtask

    //==========================================================================
    // TEST 1
    // Sparse A Transfer
    //==========================================================================

    task automatic test_sparse_a;

    begin

        $display("");
        $display("==============================================");
        $display("TEST 1: Sparse A Transfer");
        $display("==============================================");

        clear_requests();

        sparse_tile_request.valid = 1'b1;

        sparse_tile_request.values_addr_a = 32'h1000_0000;
        sparse_tile_request.values_addr_b = 32'h2000_0000;
        sparse_tile_request.metadata_addr_a = 32'h3000_0000;

        sparse_tile_request.transfer_bytes_a = 32;
        sparse_tile_request.transfer_bytes_b = 0;
        sparse_tile_request.metadata_transfer_bytes = 0;

        sparse_tile_request.bank_a = 4'd0;
        sparse_tile_request.bank_b = 4'd1;
        sparse_tile_request.metadata_bank = 4'd2;

        @(negedge clk);

        sparse_tile_request.valid = 1'b0;

        wait(done || error);

        if (error) begin
            $display("[FAIL] Sparse A transfer reported error.");
        end
        else begin
            $display("[PASS] Sparse A transfer completed.");
        end

        @(negedge clk);

    end

    endtask

    //==========================================================================
    // TEST 2
    // Sparse B Transfer
    //==========================================================================

    task automatic test_sparse_b;

    begin

        $display("");
        $display("==============================================");
        $display("TEST 2: Sparse B Transfer");
        $display("==============================================");

        clear_requests();

        sparse_tile_request.valid = 1'b1;

        sparse_tile_request.values_addr_a = 32'h1000_0000;
        sparse_tile_request.values_addr_b = 32'h2000_1000;
        sparse_tile_request.metadata_addr_a = 32'h3000_0000;

        sparse_tile_request.transfer_bytes_a = 0;
        sparse_tile_request.transfer_bytes_b = 64;
        sparse_tile_request.metadata_transfer_bytes = 0;

        sparse_tile_request.bank_a = 4'd0;
        sparse_tile_request.bank_b = 4'd1;
        sparse_tile_request.metadata_bank = 4'd2;

        @(negedge clk);

        sparse_tile_request.valid = 1'b0;

        wait(done || error);

        if (error)
            $display("[FAIL] Sparse B transfer reported error.");
        else
            $display("[PASS] Sparse B transfer completed.");

        @(negedge clk);

    end

    endtask

    //==========================================================================
    // TEST 3
    // Metadata Transfer
    //==========================================================================

    task automatic test_metadata;

    begin

        $display("");
        $display("==============================================");
        $display("TEST 3: Sparse Metadata Transfer");
        $display("==============================================");

        clear_requests();

        sparse_tile_request.valid = 1'b1;

        sparse_tile_request.values_addr_a = 32'h1000_0000;
        sparse_tile_request.values_addr_b = 32'h2000_0000;
        sparse_tile_request.metadata_addr_a = 32'h3000_0000;

        sparse_tile_request.transfer_bytes_a = 0;
        sparse_tile_request.transfer_bytes_b = 0;
        sparse_tile_request.metadata_transfer_bytes = 16;

        sparse_tile_request.bank_a = 4'd0;
        sparse_tile_request.bank_b = 4'd1;
        sparse_tile_request.metadata_bank = 4'd2;

        @(negedge clk);

        sparse_tile_request.valid = 1'b0;

        wait(done || error);

        if (error)
            $display("[FAIL] Metadata transfer reported error.");
        else
            $display("[PASS] Metadata transfer completed.");

        @(negedge clk);

    end

    endtask

    //==========================================================================
    // TEST 4
    // Complete Sparse Tile
    //
    // A -> B -> Metadata
    //==========================================================================

    task automatic test_complete_sparse_tile;

    begin

        $display("");
        $display("==============================================");
        $display("TEST 4: Complete Sparse Tile");
        $display("==============================================");

        clear_requests();

        sparse_tile_request.valid = 1'b1;
        sparse_tile_request.last_tile = 1'b1;

        sparse_tile_request.tile_context.tile_row = 0;
        sparse_tile_request.tile_context.tile_col = 0;
        sparse_tile_request.tile_context.tile_k   = 0;

        sparse_tile_request.values_addr_a =
            32'h1000_0000;

        sparse_tile_request.values_addr_b =
            32'h2000_0000;

        sparse_tile_request.metadata_addr_a =
            32'h3000_0000;

        sparse_tile_request.addr_c =
            32'h4000_0000;

        sparse_tile_request.rows = 8;
        sparse_tile_request.cols = 8;
        sparse_tile_request.k_size = 8;

        sparse_tile_request.transfer_bytes_a = 32;
        sparse_tile_request.transfer_bytes_b = 64;
        sparse_tile_request.metadata_transfer_bytes = 16;

        sparse_tile_request.bank_a = 4'd0;
        sparse_tile_request.bank_b = 4'd1;
        sparse_tile_request.bank_c = 4'd3;
        sparse_tile_request.metadata_bank = 4'd2;

        memory_request_count = 0;

        @(negedge clk);

        sparse_tile_request.valid = 1'b0;

        wait(done || error);

        if (error) begin

            $display("[FAIL] Complete sparse tile reported error.");

        end
        else if (memory_request_count != 3) begin

            $display(
                "[FAIL] Expected 3 memory requests, got %0d",
                memory_request_count
            );

        end
        else begin

            $display(
                "[PASS] Complete sparse tile: A -> B -> Metadata"
            );

        end

        @(negedge clk);

    end

    endtask

    //==========================================================================
    // Main Test Sequence
    //==========================================================================

    initial begin

        // Defaults
        tile_request = '0;
        sparse_tile_request = '0;

        mem_ready = 1'b1;
        mem_rready = 1'b1;
        spad_ready = 1'b1;

        rst = 1'b1;

        repeat (5)
            @(negedge clk);

        rst = 1'b0;

        repeat (2)
            @(negedge clk);

        //----------------------------------------------------------------------
        // Run tests
        //----------------------------------------------------------------------

        test_sparse_a();

        test_sparse_b();

        test_metadata();

        test_complete_sparse_tile();

        //----------------------------------------------------------------------
        // Final
        //----------------------------------------------------------------------

        $display("");
        $display("==============================================");
        $display("Sparse Transfer Engine Test Complete");
        $display("==============================================");

        #100;

        $finish;

    end

endmodule