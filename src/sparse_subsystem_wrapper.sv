//==============================================================================
// Module      : sparse_subsystem_wrapper
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   Descriptor-driven front end for the sparse 8x8 datapath.
//
//   Descriptor
//       |
//       v
//   sparse_tile_generator (single fixed 8x8 tile -- see Scope below)
//       |
//       v
//   Sequencer FSM (issue request -> wait transfer -> start compute -> wait
//                  compute), replicating the exact handshake that was
//                  already verified by hand in sparse_subsystem_8x8_tb.sv
//       |
//       v
//   sparse_datapath_8x8_wrapper   <-- UNMODIFIED, already verified
//       |
//       +--> Main Memory (private instance, same pattern dense_subsystem_wrapper
//       |                 already uses)
//       +--> Scratchpad / Compute
//
// Scope
// -----
//   sparse_compute_8x8_controller (inside sparse_datapath_8x8_wrapper) is a
//   fixed-size 8x8 unit -- it does not loop over multiple K-tiles the way
//   compute_controller (dense) does. So this wrapper issues exactly ONE
//   8x8 tile per descriptor, at tile_context = {row:0, col:0, k:0}.
//
//   descriptor.rows / .cols / .k are expected to be 8 for this milestone.
//   Matrices larger than 8x8 on the sparse side need a real multi-tile
//   sparse scheduler driving tile_walker in a loop (mirroring what
//   dense_scheduler already does) -- that does not exist yet and is not
//   attempted here; sparse_scheduler.sv as uploaded targets a different,
//   more granular per-operand-DMA interface that has no supporting DMA/
//   decoder modules built against it yet, so it is intentionally not used
//   by this wrapper.
//
// IMPORTANT
// ---------
//   This module does not modify sparse_datapath_8x8_wrapper.sv,
//   main_memory_model.sv, sparse_tile_generator.sv, or any other
//   already-verified module.
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

import descriptor_pkg::*;
import tile_pkg::*;

module sparse_subsystem_wrapper #(

    parameter integer BURST_BYTES      = 128,
    parameter integer DATA_WIDTH       = 64,
    parameter integer SPAD_DATA_WIDTH  = 32,
    parameter integer SPAD_ADDR_WIDTH  = 6,
    parameter bit     VERBOSE          = 1'b0

    // NOTE: main_memory_model's MEMORY_INIT_FILE is intentionally hardcoded
    // below rather than threaded through as a module parameter here --
    // Icarus Verilog (unlike VCS/Questa/Xcelium) cannot bind an explicitly
    // overridden `string` parameter passed through hierarchy (confirmed
    // with an isolated repro). Matches the hardcoded-path convention the
    // already-verified sparse_subsystem_8x8.sv used for the same reason.

)(
    //==========================================================================
    // Global
    //==========================================================================

    input logic clk,
    input logic rst,

    //==========================================================================
    // Descriptor Interface
    //==========================================================================

    input  logic        start,
    input  descriptor_t descriptor,

    output logic sparse_done,

    //==========================================================================
    // Data-Movement Status
    //==========================================================================

    output logic transfer_busy,
    output logic transfer_done,

    //==========================================================================
    // Compute Result -- the sparse datapath produces the full 8x8 tile at
    // once, unlike dense's per-element result stream.
    //==========================================================================

    output logic signed [63:0] debug_compute_result [0:7][0:7],
    output logic [31:0]        debug_compute_mac_count

);

    //==========================================================================
    // Sparse Tile Generator (combinational, single fixed 8x8 tile)
    //==========================================================================

    tile_context_t single_tile_context;

    assign single_tile_context.tile_row = 16'd0;
    assign single_tile_context.tile_col = 16'd0;
    assign single_tile_context.tile_k   = 16'd0;

    sparse_tile_request_t generated_request;

    sparse_tile_generator u_sparse_tile_generator (

        .descriptor    (descriptor),
        .current_tile  (single_tile_context),

        .num_k_tiles   (16'd1),
        .last_tile     (1'b1),

        .sparse_tile_request (generated_request)
    );

    //==========================================================================
    // Sequencer FSM
    //
    // Mirrors the exact handshake already verified in
    // sparse_subsystem_8x8_tb.sv: hold the request valid until accepted,
    // wait for transfer completion, pulse compute_start for one cycle,
    // wait for compute_done.
    //==========================================================================

    typedef enum logic [2:0] {

        SEQ_IDLE,
        SEQ_ISSUE_REQUEST,
        SEQ_WAIT_TRANSFER,
        SEQ_START_COMPUTE,
        SEQ_WAIT_COMPUTE,
        SEQ_DONE

    } seq_state_t;

    seq_state_t seq_state, seq_next;

    logic                 sparse_tile_request_valid;
    logic                 sparse_tile_request_ready;
    sparse_tile_request_t sparse_tile_request_held;

    logic compute_start;
    logic compute_busy;
    logic compute_done;

    //--------------------------------------------------------------------------
    // State Register
    //--------------------------------------------------------------------------

    always_ff @(posedge clk) begin

        if (rst)
            seq_state <= SEQ_IDLE;
        else
            seq_state <= seq_next;

    end

    //--------------------------------------------------------------------------
    // Held Request Register
    //
    // Captured once at the moment `start` is seen, so it stays stable
    // across the whole transfer/compute sequence even if `descriptor`
    // changes afterward.
    //--------------------------------------------------------------------------

    always_ff @(posedge clk) begin

        if (rst)
            sparse_tile_request_held <= '0;
        else if (seq_state == SEQ_IDLE && start)
            sparse_tile_request_held <= generated_request;

    end

    //--------------------------------------------------------------------------
    // Next-State Logic
    //--------------------------------------------------------------------------

    always_comb begin

        seq_next = seq_state;

        case (seq_state)

            SEQ_IDLE:
                if (start)
                    seq_next = SEQ_ISSUE_REQUEST;

            SEQ_ISSUE_REQUEST:
                if (sparse_tile_request_ready)
                    seq_next = SEQ_WAIT_TRANSFER;

            SEQ_WAIT_TRANSFER:
                if (transfer_done)
                    seq_next = SEQ_START_COMPUTE;

            // Hold compute_start until compute_busy actually rises, rather
            // than a fixed cycle count -- see header note on why. This
            // guarantees compute_start is seen high on whatever edge
            // sparse_datapath_8x8_wrapper's internal transfer_complete_latched
            // finally settles, however many cycles that trails transfer_done
            // by, instead of gambling on it happening within N cycles.
            SEQ_START_COMPUTE:
                if (compute_busy)
                    seq_next = SEQ_WAIT_COMPUTE;

            SEQ_WAIT_COMPUTE:
                if (compute_done)
                    seq_next = SEQ_DONE;

            SEQ_DONE:
                seq_next = SEQ_IDLE;

            default:
                seq_next = SEQ_IDLE;

        endcase

    end

    //--------------------------------------------------------------------------
    // Output Logic
    //--------------------------------------------------------------------------

    // compute_start is held HIGH for the entire SEQ_START_COMPUTE state,
    // which only ends once compute_busy actually rises (see next-state
    // logic above) -- not for a fixed number of cycles.
    //
    // sparse_datapath_8x8_wrapper's internal transfer_complete_latched can
    // trail transfer_done by an unknown number of cycles, and compute_start
    // must be seen high on the exact edge that latch is set (the original
    // hand-driven testbench documents this requirement explicitly). A fixed
    // 2-cycle hold gambled that the latch always settles within 2 cycles --
    // it passed in one Icarus build and failed differently in another
    // (OSS CAD Suite's bundled build), producing a genuine timing race:
    // rows that happened to read metadata/A before the latch caught up came
    // out wrong while others were fine, which is exactly the intermittent,
    // partial-row corruption pattern that surfaced. Holding until
    // compute_busy confirms acceptance removes the guess entirely.
    always_comb begin

        sparse_tile_request_valid = (seq_state == SEQ_ISSUE_REQUEST);
        compute_start              = (seq_state == SEQ_START_COMPUTE);
        sparse_done                = (seq_state == SEQ_DONE);

    end

    //==========================================================================
    // Sparse Datapath (already verified -- unmodified black box)
    //==========================================================================

    logic        mem_req_valid;
    logic        mem_req_ready;
    logic [31:0] mem_req_addr;
    logic [31:0] mem_req_bytes;

    logic        mem_rvalid;
    logic [63:0] mem_rdata;
    logic        mem_rlast;

    sparse_datapath_8x8_wrapper #(

        .BURST_BYTES     (BURST_BYTES),
        .DATA_WIDTH      (DATA_WIDTH),
        .SPAD_DATA_WIDTH (SPAD_DATA_WIDTH),
        .SPAD_ADDR_WIDTH (SPAD_ADDR_WIDTH),
        .VERBOSE         (VERBOSE)

    ) u_sparse_datapath (

        .clk (clk),
        .rst (rst),

        .sparse_tile_request       (sparse_tile_request_held),
        .sparse_tile_request_valid (sparse_tile_request_valid),
        .sparse_tile_request_ready (sparse_tile_request_ready),

        .mem_req_valid (mem_req_valid),
        .mem_req_ready (mem_req_ready),
        .mem_req_addr  (mem_req_addr),
        .mem_req_bytes (mem_req_bytes),

        .mem_rvalid (mem_rvalid),
        .mem_rdata  (mem_rdata),
        .mem_rlast  (mem_rlast),

        .compute_start (compute_start),
        .compute_busy  (compute_busy),
        .compute_done  (compute_done),

        .compute_result     (debug_compute_result),
        .compute_mac_count  (debug_compute_mac_count),

        .transfer_busy (transfer_busy),
        .transfer_done (transfer_done),

        .datapath_busy (),
        .datapath_done ()
    );

    //==========================================================================
    // Private Main Memory Model
    //
    // Mirrors dense_subsystem_wrapper's pattern: one private memory instance
    // per subsystem. Since descriptor_controller processes descriptors
    // serially (dense and sparse are never active at once), this is safe
    // for now. Sharing one arbitrated memory port across both subsystems is
    // flagged as follow-up work once concurrent dispatch is needed.
    //==========================================================================

    main_memory_model #(

        .DATA_WIDTH      (64),
        .MEMORY_SIZE     (65536),
        .MEMORY_LATENCY  (3),
        .MEMORY_INIT_FILE("mem files/sparse_data_memory.mem"),
        .VERBOSE         (VERBOSE)

    ) u_main_memory (

        .clk (clk),
        .rst (rst),

        .mem_req_valid (mem_req_valid),
        .mem_req_ready (mem_req_ready),
        .mem_req_addr  (mem_req_addr),
        .mem_req_bytes (mem_req_bytes),
        .mem_req_write (1'b0),

        .mem_rvalid (mem_rvalid),
        .mem_rdata  (mem_rdata),
        .mem_rlast  (mem_rlast)
    );

endmodule

`default_nettype wire