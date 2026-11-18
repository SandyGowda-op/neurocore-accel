//==============================================================================
//
// Module      : transfer_engine
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//      Generic DMA Transfer Engine
//
//      Dense execution:
//          Phase A : Main Memory A -> Scratchpad bank_a
//          Phase B : Main Memory B -> Scratchpad bank_b
//
//      Sparse execution:
//          Phase A : Compressed A values -> Scratchpad bank_a
//          Phase B : B values             -> Scratchpad bank_b
//          Phase M : Metadata             -> Scratchpad metadata_bank
//
//      IMPORTANT:
//
//          The main-memory interface has NO mem_rready.
//
//          Therefore memory data cannot be stalled while the scratchpad
//          controller is busy.
//
//          A burst-data FIFO is used to decouple:
//
//              Main Memory -> Transfer Engine
//
//          from:
//
//              Transfer Engine -> Scratchpad Controller
//
//      This prevents memory beats from being lost while the
//      scratchpad_controller performs its LOW/HIGH 32-bit writes.
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

import tile_pkg::*;

module transfer_engine #(
    parameter integer BURST_BYTES = 128,
    parameter integer DATA_WIDTH  = 64
)(
    //--------------------------------------------------------------------------
    // Global
    //--------------------------------------------------------------------------

    input logic clk,
    input logic rst,

    //--------------------------------------------------------------------------
    // Dense Scheduler Interface
    //--------------------------------------------------------------------------

    input  tile_request_t tile_request,
    input  logic          tile_request_valid,
    output logic          tile_request_ready,

    //--------------------------------------------------------------------------
    // Sparse Scheduler Interface
    //--------------------------------------------------------------------------

    input  sparse_tile_request_t sparse_tile_request,
    input  logic                 sparse_tile_request_valid,
    output logic                 sparse_tile_request_ready,

    //--------------------------------------------------------------------------
    // Main Memory Request Interface
    //--------------------------------------------------------------------------

    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    output logic [31:0] mem_req_bytes,

    //--------------------------------------------------------------------------
    // Main Memory Read Data Interface
    //
    // No mem_rready exists in the established interface.
    //--------------------------------------------------------------------------

    input  logic        mem_rvalid,
    input  logic [63:0] mem_rdata,
    input  logic        mem_rlast,

    //--------------------------------------------------------------------------
    // Scratchpad Interface
    //--------------------------------------------------------------------------

    output logic        spad_write_enable,
    output logic [3:0]  spad_bank,
    output logic [31:0] spad_address,
    output logic [63:0] spad_write_data,
    input  logic        spad_ready,

    //--------------------------------------------------------------------------
    // Status
    //--------------------------------------------------------------------------

    output logic transfer_busy,
    output logic transfer_done
);

    //==========================================================================
    // Local Parameters
    //==========================================================================

    localparam integer BYTES_PER_BEAT = DATA_WIDTH / 8;

    localparam integer BURST_BEATS =
        (BURST_BYTES + BYTES_PER_BEAT - 1) / BYTES_PER_BEAT;

    localparam integer FIFO_DEPTH = BURST_BEATS;

    localparam integer FIFO_PTR_WIDTH =
        (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);

    //==========================================================================
    // Parameter Checking
    //==========================================================================

    initial begin

        if (DATA_WIDTH != 64)
            $fatal("transfer_engine: DATA_WIDTH must currently be 64");

        if (BURST_BYTES <= 0)
            $fatal("transfer_engine: BURST_BYTES must be > 0");

        if ((BURST_BYTES % BYTES_PER_BEAT) != 0)
            $fatal("transfer_engine: BURST_BYTES must be a multiple of DATA_WIDTH/8");

    end

    //==========================================================================
    // Transfer Phase
    //
    // Dense:
    //      A -> B
    //
    // Sparse:
    //      A -> B -> Metadata
    //==========================================================================

    typedef enum logic [1:0]
    {
        TRANSFER_A,
        TRANSFER_B,
        TRANSFER_METADATA
    } transfer_phase_t;

    transfer_phase_t transfer_phase;

    //==========================================================================
    // Transfer Engine FSM
    //==========================================================================

    typedef enum logic [2:0]
    {
        IDLE,
        REQUEST_BURST,
        WAIT_REQUEST_ACCEPT,
        WAIT_DATA,
        COMPLETE
    } transfer_state_t;

    transfer_state_t state;
    transfer_state_t next_state;

    //==========================================================================
    // Dense Request
    //==========================================================================

    tile_request_t current_request;

    //==========================================================================
    // Sparse Request
    //==========================================================================

    sparse_tile_request_t current_sparse_request;

    //==========================================================================
    // Mode
    //==========================================================================

    logic sparse_active;

    //==========================================================================
    // DMA Working Registers
    //==========================================================================

    logic [31:0] current_address;
    logic [31:0] bytes_remaining;

    // Scratchpad address is a BYTE address.
    // scratchpad_controller converts byte address -> word address.

    logic [31:0] current_spad_write_addr;

    logic [31:0] current_burst_bytes;

    //==========================================================================
    // Burst Generator
    //==========================================================================

    logic [31:0] burst_bytes;

    always_comb begin

        if (bytes_remaining >= BURST_BYTES)
            burst_bytes = BURST_BYTES;
        else
            burst_bytes = bytes_remaining;

    end

    //==========================================================================
    // Burst Data FIFO
    //
    // The FIFO stores memory beats while the scratchpad controller is busy.
    //
    // One FIFO entry = one 64-bit memory beat.
    //
    // For the default configuration:
    //
    //      BURST_BYTES = 128
    //      DATA_WIDTH  = 64
    //
    //      FIFO_DEPTH = 128 / 8 = 16 beats
    //
    //==========================================================================

    logic [63:0] fifo_data [0:FIFO_DEPTH-1];
    logic        fifo_last [0:FIFO_DEPTH-1];

    logic [FIFO_PTR_WIDTH-1:0] fifo_wr_ptr;
    logic [FIFO_PTR_WIDTH-1:0] fifo_rd_ptr;

    logic [FIFO_PTR_WIDTH:0] fifo_count;

    logic fifo_full;
    logic fifo_empty;

    assign fifo_full =
        (fifo_count == FIFO_DEPTH);

    assign fifo_empty =
        (fifo_count == 0);

    //--------------------------------------------------------------------------
    // FIFO Write
    //
    // A memory beat is captured whenever mem_rvalid is asserted.
    //
    // Because the burst FIFO is sized to hold the complete burst, normal
    // operation cannot overflow it.
    //--------------------------------------------------------------------------

    logic fifo_write;
    logic fifo_read;

    assign fifo_write =
        (state == WAIT_DATA) &&
        mem_rvalid &&
        !fifo_full;

    //--------------------------------------------------------------------------
    // FIFO Read
    //
    // A beat is presented to the scratchpad controller until it is accepted.
    //--------------------------------------------------------------------------

    assign fifo_read =
        (state == WAIT_DATA) &&
        !fifo_empty &&
        spad_ready;

    //==========================================================================
    // FIFO Sequential Logic
    //==========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
            fifo_count  <= '0;

        end
        else begin

            //------------------------------------------------------------------
            // FIFO write
            //------------------------------------------------------------------

            if (fifo_write) begin

                fifo_data[fifo_wr_ptr] <= mem_rdata;
                fifo_last[fifo_wr_ptr] <= mem_rlast;

                if (fifo_wr_ptr == FIFO_DEPTH-1)
                    fifo_wr_ptr <= '0;
                else
                    fifo_wr_ptr <= fifo_wr_ptr + 1'b1;

            end

            //------------------------------------------------------------------
            // FIFO read
            //------------------------------------------------------------------

            if (fifo_read) begin

                if (fifo_rd_ptr == FIFO_DEPTH-1)
                    fifo_rd_ptr <= '0;
                else
                    fifo_rd_ptr <= fifo_rd_ptr + 1'b1;

            end

            //------------------------------------------------------------------
            // FIFO count
            //------------------------------------------------------------------

            case ({fifo_write, fifo_read})

                2'b10:
                    fifo_count <= fifo_count + 1'b1;

                2'b01:
                    fifo_count <= fifo_count - 1'b1;

                default:
                    fifo_count <= fifo_count;

            endcase

        end

    end

    //==========================================================================
    // Burst Completion Tracking
    //
    // mem_rlast tells us that the final memory beat of the current burst
    // has arrived.
    //
    // However, the burst is NOT considered completely consumed until that
    // final beat has also been accepted by the scratchpad controller.
    //==========================================================================

    logic burst_last_received;
    logic burst_last_consumed;

    //==========================================================================
    // Scheduler Ready
    //
    // Only one request type may be accepted at a time.
    //
    // Dense has priority when both valid signals are asserted.
    //==========================================================================

    assign tile_request_ready =
        (state == IDLE);

    assign sparse_tile_request_ready =
        (state == IDLE) &&
        !tile_request_valid;

    //==========================================================================
    // Current FIFO Head
    //==========================================================================

    logic [63:0] fifo_head_data;
    logic        fifo_head_last;

    always_comb begin

        if (!fifo_empty) begin
            fifo_head_data = fifo_data[fifo_rd_ptr];
            fifo_head_last = fifo_last[fifo_rd_ptr];
        end
        else begin
            fifo_head_data = '0;
            fifo_head_last = 1'b0;
        end

    end

    //==========================================================================
    // FIFO Last Tracking
    //==========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            burst_last_received <= 1'b0;
            burst_last_consumed  <= 1'b0;

        end
        else begin

            //------------------------------------------------------------------
            // A memory burst has ended when mem_rlast is captured.
            //------------------------------------------------------------------

            if (fifo_write && mem_rlast)
                burst_last_received <= 1'b1;

            //------------------------------------------------------------------
            // The final beat has reached the scratchpad controller.
            //------------------------------------------------------------------

            if (fifo_read && fifo_head_last)
                burst_last_consumed <= 1'b1;

            //------------------------------------------------------------------
            // New burst starts.
            //------------------------------------------------------------------

            if (state == REQUEST_BURST &&
                next_state == WAIT_DATA) begin

                burst_last_received <= 1'b0;
                burst_last_consumed  <= 1'b0;

            end

        end

    end

    //==========================================================================
    // Phase Transition Helper
    //
    // This is evaluated only after the entire burst has been drained from
    // the FIFO into the scratchpad.
    //==========================================================================

    logic burst_fully_consumed;

    assign burst_fully_consumed =
        burst_last_consumed &&
        fifo_empty;

    //==========================================================================
    // FSM Sequential Logic
    //==========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            state <= IDLE;

            current_request        <= '0;
            current_sparse_request <= '0;

            transfer_phase <= TRANSFER_A;

            sparse_active <= 1'b0;

            current_address <= '0;
            bytes_remaining <= '0;

            current_spad_write_addr <= '0;

            current_burst_bytes <= '0;

        end

        else begin

            state <= next_state;

            //------------------------------------------------------------------
            // Accept DENSE tile request
            //------------------------------------------------------------------

            if (state == IDLE &&
                tile_request_valid &&
                tile_request_ready) begin

                current_request <= tile_request;

                sparse_active <= 1'b0;

                transfer_phase <= TRANSFER_A;

                current_address <=
                    tile_request.addr_a;

                bytes_remaining <=
                    tile_request.transfer_bytes;

                current_spad_write_addr <=
                    '0;

            end

            //------------------------------------------------------------------
            // Accept SPARSE tile request
            //------------------------------------------------------------------

            else if (state == IDLE &&
                     sparse_tile_request_valid &&
                     sparse_tile_request_ready) begin

                current_sparse_request <=
                    sparse_tile_request;

                sparse_active <= 1'b1;

                transfer_phase <= TRANSFER_A;

                current_address <=
                    sparse_tile_request.values_addr_a;

                bytes_remaining <=
                    sparse_tile_request.transfer_bytes_a;

                current_spad_write_addr <=
                    '0;

            end

            //------------------------------------------------------------------
            // Latch burst size
            //------------------------------------------------------------------

            if (state == REQUEST_BURST) begin

                current_burst_bytes <=
                    burst_bytes;

            end

            //------------------------------------------------------------------
            // Memory beat bookkeeping
            //
            // IMPORTANT:
            //
            // current_spad_write_addr is NOT advanced here.
            //
            // It advances only when the scratchpad controller actually
            // accepts the beat.
            //------------------------------------------------------------------

            if (fifo_read) begin

                current_spad_write_addr <=
                    current_spad_write_addr +
                    BYTES_PER_BEAT;

            end

            // [te_merge] phase/address updates merged into main FSM block
            if (state == WAIT_DATA &&
                burst_fully_consumed) begin

                //------------------------------------------------------------------
                // Final burst of current phase
                //------------------------------------------------------------------

                if (bytes_remaining == current_burst_bytes) begin

                    //----------------------------------------------------------------
                    // Sparse
                    //----------------------------------------------------------------

                    if (sparse_active) begin

                        case (transfer_phase)

                            TRANSFER_A: begin

                                if (current_sparse_request.transfer_bytes_b != 0) begin

                                    transfer_phase <= TRANSFER_B;

                                    current_address <=
                                        current_sparse_request.values_addr_b;

                                    bytes_remaining <=
                                        current_sparse_request.transfer_bytes_b;

                                    current_spad_write_addr <=
                                        '0;

                                end

                                else if (current_sparse_request.metadata_transfer_bytes != 0) begin

                                    transfer_phase <= TRANSFER_METADATA;

                                    current_address <=
                                        current_sparse_request.metadata_addr_a;

                                    bytes_remaining <=
                                        current_sparse_request.metadata_transfer_bytes;

                                    current_spad_write_addr <=
                                        '0;

                                end

                                else begin

                                    bytes_remaining <= '0;

                                end

                            end

                            TRANSFER_B: begin

                                if (current_sparse_request.metadata_transfer_bytes != 0) begin

                                    transfer_phase <= TRANSFER_METADATA;

                                    current_address <=
                                        current_sparse_request.metadata_addr_a;

                                    bytes_remaining <=
                                        current_sparse_request.metadata_transfer_bytes;

                                    current_spad_write_addr <=
                                        '0;

                                end

                                else begin

                                    bytes_remaining <= '0;

                                end

                            end

                            TRANSFER_METADATA: begin

                                bytes_remaining <= '0;

                            end

                            default: begin

                                bytes_remaining <= '0;

                            end

                        endcase

                    end

                    //----------------------------------------------------------------
                    // Dense
                    //----------------------------------------------------------------

                    else begin

                        if (transfer_phase == TRANSFER_A) begin

                            if (current_request.transfer_bytes_b != 0) begin

                                transfer_phase <= TRANSFER_B;

                                current_address <=
                                    current_request.addr_b;

                                bytes_remaining <=
                                    current_request.transfer_bytes_b;

                                current_spad_write_addr <=
                                    '0;

                            end

                            else begin

                                bytes_remaining <= '0;

                            end

                        end

                        else begin

                            bytes_remaining <= '0;

                        end

                    end

                end

                //------------------------------------------------------------------
                // More bursts remain
                //------------------------------------------------------------------

                else begin

                    current_address <=
                        current_address +
                        current_burst_bytes;

                    bytes_remaining <=
                        bytes_remaining -
                        current_burst_bytes;

                end

            end

        end

    end


    //==========================================================================
    // Next State Logic
    //==========================================================================

    always_comb begin

        next_state = state;

        case (state)

            //==================================================================
            // IDLE
            //==================================================================

            IDLE: begin

                //----------------------------------------------------------------
                // Dense request
                //----------------------------------------------------------------

                if (tile_request_valid &&
                    tile_request_ready) begin

                    if (tile_request.transfer_bytes == 0) begin

                        if (tile_request.transfer_bytes_b == 0)
                            next_state = COMPLETE;
                        else
                            next_state = REQUEST_BURST;

                    end
                    else begin

                        next_state = REQUEST_BURST;

                    end

                end

                //----------------------------------------------------------------
                // Sparse request
                //----------------------------------------------------------------

                else if (sparse_tile_request_valid &&
                         sparse_tile_request_ready) begin

                    if (sparse_tile_request.transfer_bytes_a == 0) begin

                        if (sparse_tile_request.transfer_bytes_b != 0)
                            next_state = REQUEST_BURST;

                        else if (sparse_tile_request.metadata_transfer_bytes != 0)
                            next_state = REQUEST_BURST;

                        else
                            next_state = COMPLETE;

                    end
                    else begin

                        next_state = REQUEST_BURST;

                    end

                end

            end

            //==================================================================
            // REQUEST_BURST
            //==================================================================

            REQUEST_BURST: begin

                if (bytes_remaining == 0) begin

                    //----------------------------------------------------------------
                    // Zero-length phase transitions
                    //----------------------------------------------------------------

                    if (sparse_active) begin

                        case (transfer_phase)

                            TRANSFER_A: begin

                                if (current_sparse_request.transfer_bytes_b != 0)
                                    next_state = REQUEST_BURST;

                                else if (current_sparse_request.metadata_transfer_bytes != 0)
                                    next_state = REQUEST_BURST;

                                else
                                    next_state = COMPLETE;

                            end

                            TRANSFER_B: begin

                                if (current_sparse_request.metadata_transfer_bytes != 0)
                                    next_state = REQUEST_BURST;

                                else
                                    next_state = COMPLETE;

                            end

                            TRANSFER_METADATA: begin

                                next_state = COMPLETE;

                            end

                            default: begin

                                next_state = COMPLETE;

                            end

                        endcase

                    end

                    else begin

                        if (transfer_phase == TRANSFER_A &&
                            current_request.transfer_bytes_b != 0) begin

                            next_state = REQUEST_BURST;

                        end
                        else begin

                            next_state = COMPLETE;

                        end

                    end

                end

                else if (mem_req_ready) begin

                    next_state = WAIT_DATA;

                end

                else begin

                    next_state = WAIT_REQUEST_ACCEPT;

                end

            end

            //==================================================================
            // WAIT_REQUEST_ACCEPT
            //==================================================================

            WAIT_REQUEST_ACCEPT: begin

                if (mem_req_ready)
                    next_state = WAIT_DATA;

            end

            //==================================================================
            // WAIT_DATA
            //
            // Memory beats are collected into the FIFO.
            //
            // The state remains here until:
            //
            //      1. mem_rlast has been received
            //      2. final beat has been written to scratchpad
            //      3. FIFO is empty
            //
            //==================================================================

            WAIT_DATA: begin

                if (burst_fully_consumed) begin

                    //----------------------------------------------------------------
                    // Final burst of current phase
                    //----------------------------------------------------------------

                    if (bytes_remaining == current_burst_bytes) begin

                        if (sparse_active) begin

                            case (transfer_phase)

                                //--------------------------------------------------
                                // Sparse A -> B / Metadata
                                //--------------------------------------------------

                                TRANSFER_A: begin

                                    if (current_sparse_request.transfer_bytes_b != 0)
                                        next_state = REQUEST_BURST;

                                    else if (current_sparse_request.metadata_transfer_bytes != 0)
                                        next_state = REQUEST_BURST;

                                    else
                                        next_state = COMPLETE;

                                end

                                //--------------------------------------------------
                                // Sparse B -> Metadata
                                //--------------------------------------------------

                                TRANSFER_B: begin

                                    if (current_sparse_request.metadata_transfer_bytes != 0)
                                        next_state = REQUEST_BURST;

                                    else
                                        next_state = COMPLETE;

                                end

                                //--------------------------------------------------
                                // Sparse Metadata complete
                                //--------------------------------------------------

                                TRANSFER_METADATA: begin

                                    next_state = COMPLETE;

                                end

                                default: begin

                                    next_state = COMPLETE;

                                end

                            endcase

                        end

                        //----------------------------------------------------------------
                        // Dense execution
                        //----------------------------------------------------------------

                        else begin

                            if (transfer_phase == TRANSFER_A) begin

                                if (current_request.transfer_bytes_b != 0)
                                    next_state = REQUEST_BURST;

                                else
                                    next_state = COMPLETE;

                            end

                            else begin

                                next_state = COMPLETE;

                            end

                        end

                    end

                    //----------------------------------------------------------------
                    // More bursts remain in current phase
                    //----------------------------------------------------------------

                    else begin

                        next_state = REQUEST_BURST;

                    end

                end

            end

            //==================================================================
            // COMPLETE
            //==================================================================

            COMPLETE: begin

                next_state = IDLE;

            end

            //==================================================================
            // Recovery
            //==================================================================

            default: begin

                next_state = IDLE;

            end

        endcase

    end

    //==========================================================================
    // Output Logic
    //==========================================================================

    always_comb begin

        //----------------------------------------------------------------------
        // Defaults
        //----------------------------------------------------------------------

        mem_req_valid = 1'b0;
        mem_req_addr  = '0;
        mem_req_bytes = '0;

        spad_write_enable = 1'b0;
        spad_bank         = '0;
        spad_address      = '0;
        spad_write_data   = '0;

        transfer_busy = 1'b0;
        transfer_done = 1'b0;

        //----------------------------------------------------------------------
        // State-dependent outputs
        //----------------------------------------------------------------------

        case (state)

            //==================================================================
            // IDLE
            //==================================================================

            IDLE: begin

            end

            //==================================================================
            // REQUEST_BURST
            //==================================================================

            REQUEST_BURST: begin

                transfer_busy = 1'b1;

                if (bytes_remaining != 0) begin

                    mem_req_valid = 1'b1;

                    mem_req_addr =
                        current_address;

                    mem_req_bytes =
                        burst_bytes;

                end

            end

            //==================================================================
            // WAIT_REQUEST_ACCEPT
            //==================================================================

            WAIT_REQUEST_ACCEPT: begin

                transfer_busy = 1'b1;

                mem_req_valid = 1'b1;

                mem_req_addr =
                    current_address;

                mem_req_bytes =
                    burst_bytes;

            end

            //==================================================================
            // WAIT_DATA
            //
            // Memory -> FIFO
            //
            // FIFO -> Scratchpad
            //
            // The scratchpad write is held until spad_ready is asserted.
            //==================================================================

            WAIT_DATA: begin

                transfer_busy = 1'b1;

                if (!fifo_empty) begin

                    spad_write_enable = 1'b1;

                    spad_write_data =
                        fifo_head_data;

                    spad_address =
                        current_spad_write_addr;

                    //----------------------------------------------------------------
                    // Dense / Sparse bank selection
                    //----------------------------------------------------------------

                    if (sparse_active) begin

                        case (transfer_phase)

                            TRANSFER_A:
                                spad_bank =
                                    current_sparse_request.bank_a;

                            TRANSFER_B:
                                spad_bank =
                                    current_sparse_request.bank_b;

                            TRANSFER_METADATA:
                                spad_bank =
                                    current_sparse_request.metadata_bank;

                            default:
                                spad_bank = '0;

                        endcase

                    end

                    else begin

                        if (transfer_phase == TRANSFER_A)
                            spad_bank =
                                current_request.bank_a;
                        else
                            spad_bank =
                                current_request.bank_b;

                    end

                end

            end

            //==================================================================
            // COMPLETE
            //==================================================================

            COMPLETE: begin

                transfer_done = 1'b1;

            end

            default: begin

            end

        endcase

    end

endmodule

`default_nettype wire