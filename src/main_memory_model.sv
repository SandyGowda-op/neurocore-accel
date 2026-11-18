//==============================================================================
// Module      : main_memory_model
//
// Description :
//   Behavioral Main Memory Model for DMA verification.
//
//   Features
//   ----------
//   - Fixed read latency
//   - Burst read support
//   - Configurable DRAM size
//   - Configurable beat width
//   - Address translation from CPU address space
//   - Safe out-of-range protection
//
//   Memory read protocol:
//
//       mem_rvalid
//       mem_rdata
//       mem_rlast
//
//   There is intentionally NO mem_rready signal.
//   A memory beat is consumed whenever mem_rvalid is asserted.
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module main_memory_model #(

    parameter integer DATA_WIDTH     = 64,
    parameter integer MEMORY_SIZE    = 65536,
    parameter integer MEMORY_LATENCY = 3,
    parameter string MEMORY_INIT_FILE =
    "mem files/data_memory.mem",
    parameter bit VERBOSE = 1'b0

)(

    input  logic clk,
    input logic rst,

    //==========================================================
    // DMA Request Channel
    //==========================================================

    input  logic        mem_req_valid,
    output logic        mem_req_ready,
    input  logic [31:0] mem_req_addr,
    input  logic [31:0] mem_req_bytes,
    input  logic        mem_req_write,

    //==========================================================
    // DMA Read Data Channel
    //==========================================================

    output logic        mem_rvalid,
    output logic [63:0]  mem_rdata,
    output logic        mem_rlast

);

localparam integer BYTES_PER_BEAT = DATA_WIDTH / 8;

//==============================================================================
// Simulated Architectural Memory Map
//==============================================================================
//
// Descriptor-visible addresses:
//
//     0x1000_0000 : Matrix A
//     0x1000_0100 : Matrix B
//     0x1000_0200 : Matrix C
//
// These are NOT physical indices into the behavioral array.
//
//==============================================================================

// Flat map: physical index = addr - MEM_BASE. Window layout is now owned by
// the data generator / descriptors, not by this model. The old layout
// (A +0x000, B +0x100, meta +0x200) is the identity mapping, so existing
// .mem images remain valid unchanged.
parameter logic [31:0] MEM_BASE = 32'h1000_0000;

//==============================================================================
// Behavioral Memory
//==============================================================================

logic [7:0] memory [0:MEMORY_SIZE-1];

//==============================================================================
// Memory Initialization
//==============================================================================

integer init_i;

initial begin

    for (init_i = 0; init_i < MEMORY_SIZE; init_i = init_i + 1)
        memory[init_i] = 8'h00;   // no X on short images

    $readmemh(MEMORY_INIT_FILE, memory);

end

//==============================================================================
// FSM
//==============================================================================

typedef enum logic [1:0]
{
    IDLE,
    WAIT_LATENCY,
    STREAM_DATA,
    COMPLETE

} memory_state_t;

memory_state_t state;
memory_state_t next_state;

//==============================================================================
// Registers
//==============================================================================

logic [31:0] current_address;

logic [15:0] latency_counter;
logic [15:0] beat_counter;
logic [15:0] total_beats;

logic [63:0] read_data;
logic [31:0] beat_address;

//==============================================================================
// FSM Register
//==============================================================================

always_ff @(posedge clk) begin

    if (rst) begin

        state           <= IDLE;
        current_address <= '0;
        latency_counter <= '0;
        beat_counter    <= '0;
        total_beats     <= '0;

    end

    else begin

        //----------------------------------------------------------------------
        // State Register
        //----------------------------------------------------------------------

        state <= next_state;

        //----------------------------------------------------------------------
        // Accept New DMA Request
        //----------------------------------------------------------------------

        if (state == IDLE &&
            mem_req_valid &&
            mem_req_ready)
        begin

            current_address <= mem_req_addr;

            latency_counter <= '0;
            beat_counter    <= '0;

            total_beats <=
                mem_req_bytes / BYTES_PER_BEAT;

            if (VERBOSE) begin
                $display("[%0t] MEM : Request Accepted", $time);

                $display("        Address = %08h",
                         mem_req_addr);

                $display("        Bytes   = %0d",
                         mem_req_bytes);

                $display("        Beats   = %0d",
                         mem_req_bytes / BYTES_PER_BEAT);
            end

        end

        //----------------------------------------------------------------------
        // Memory Latency Counter
        //----------------------------------------------------------------------

        if (state == WAIT_LATENCY)
            latency_counter <= latency_counter + 1'b1;

        else
            latency_counter <= '0;

        //----------------------------------------------------------------------
        // Beat Counter
        //
        // A beat is consumed whenever mem_rvalid is asserted.
        // There is no mem_rready handshake.
        //----------------------------------------------------------------------

        if (state == STREAM_DATA &&
            mem_rvalid)
        begin

            if (!mem_rlast)
                beat_counter <= beat_counter + 1'b1;

        end

        else if (state != STREAM_DATA)
        begin

            beat_counter <= '0;

        end

    end

end

//==============================================================================
// Next State Logic
//==============================================================================

always_comb begin

    next_state = state;

    case (state)

        //======================================================================
        // Wait for DMA request
        //======================================================================

        IDLE:
        begin

            if (mem_req_valid &&
                mem_req_ready)
            begin

                next_state = WAIT_LATENCY;

            end

        end

        //======================================================================
        // Model DRAM latency
        //======================================================================

        WAIT_LATENCY:
        begin

            if (latency_counter >= MEMORY_LATENCY)
            begin

                next_state = STREAM_DATA;

            end

        end

        //======================================================================
        // Stream burst data
        //
        // Complete when the final valid beat is produced.
        //======================================================================

        STREAM_DATA:
        begin

            if (mem_rvalid &&
                mem_rlast)
            begin

                next_state = COMPLETE;

            end

        end

        //======================================================================
        // One-cycle completion state
        //======================================================================

        COMPLETE:
        begin

            next_state = IDLE;

        end

        //======================================================================
        // Safety
        //======================================================================

        default:
        begin

            next_state = IDLE;

        end

    endcase

end

//==============================================================================
// Output Logic
//==============================================================================

always_comb begin

    //--------------------------------------------------------------------------

    // Defaults

    //--------------------------------------------------------------------------

    mem_req_ready = 1'b0;

    mem_rvalid = 1'b0;
    mem_rdata  = '0;
    mem_rlast  = 1'b0;

    //--------------------------------------------------------------------------
    // State Outputs
    //--------------------------------------------------------------------------

    case (state)

        //======================================================================
        // Ready to accept a DMA request
        //======================================================================

        IDLE:
        begin

            mem_req_ready = 1'b1;

        end

        //======================================================================
        // Simulate DRAM latency
        //======================================================================

        WAIT_LATENCY:
        begin

            // No outputs asserted.

        end

        //======================================================================
        // Stream burst data
        //======================================================================

        STREAM_DATA:
        begin

            mem_rvalid = 1'b1;

            mem_rdata = read_data;

            //------------------------------------------------------------------
            // Assert LAST on final beat
            //------------------------------------------------------------------

            if (beat_counter == (total_beats - 1))
            begin

                mem_rlast = 1'b1;

            end

        end

        //======================================================================
        // Transfer Complete
        //======================================================================

        COMPLETE:
        begin

            // Nothing to drive.

        end

        default:
        begin

        end

    endcase

end

//==============================================================================
// Read Data Combiner
//==============================================================================

integer i;

always @(state or current_address or beat_counter) begin  // [fast_memmodel]

    read_data    = '0;
    beat_address = '0;

    //--------------------------------------------------------------------------
    // Only produce data while streaming
    //--------------------------------------------------------------------------

    if (state == STREAM_DATA)
    begin

        //======================================================================
        // Flat address translation (descriptor address -> array index)
        //======================================================================

        if (current_address >= MEM_BASE)
            beat_address = (current_address - MEM_BASE) +
                           (beat_counter * BYTES_PER_BEAT);
        else
            beat_address = MEMORY_SIZE;   // below base -> OOB

        //======================================================================
        // Assemble one 64-bit beat
        //======================================================================

        for (i = 0; i < BYTES_PER_BEAT; i = i + 1)
        begin

            if ((beat_address + i) < MEMORY_SIZE)
            begin

                read_data[(i*8) +: 8] =
                    memory[beat_address + i];

            end

            else
            begin

                //----------------------------------------------------------------
                // Out-of-range access
                //----------------------------------------------------------------

                read_data[(i*8) +: 8] =
                    8'h00;

            end

        end

    end

end

//==============================================================================
// Debug
//==============================================================================

integer oob_beats = 0;

always_ff @(posedge clk) begin
    if (!rst && state == STREAM_DATA && mem_rvalid &&
        (beat_address + BYTES_PER_BEAT > MEMORY_SIZE)) begin
        oob_beats <= oob_beats + 1;
        $display("MEM_OOB [%0t] %m addr=%08h beat=%0d", $time,
                 current_address, beat_counter);
    end
end

always_ff @(posedge clk) begin

    if (!rst &&
        state == STREAM_DATA &&
        mem_rvalid &&
        VERBOSE)
    begin

        $display(
            "[%0t] MEM Beat=%0d Addr=%08h RLAST=%b Data=%016h",
            $time,
            beat_counter,
            current_address +
            (beat_counter * BYTES_PER_BEAT),
            mem_rlast,
            mem_rdata
        );

    end

end

endmodule

`default_nettype wire