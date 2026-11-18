//==============================================================================
// Module      : accelerator_top
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   Ties the descriptor front end to the dense/sparse scheduler engine and
//   drives a sequence of NUM_JOBS descriptors (indices 0 .. NUM_JOBS-1),
//   one at a time.
//
//   descriptor_memory (CPU port, preloaded externally)
//       |  (DFU port)
//       v
//   descriptor_fetch_unit
//       |
//       v
//   descriptor_controller
//       |
//       v
//   scheduler_engine ---> dense_subsystem_wrapper
//                    \--> sparse_subsystem_wrapper
//
// Fix folded in here (not in any of the above modules) : descriptor_fetch_
// unit's `descriptor_valid` output is a LEVEL signal (comb off the last
// committed descriptor_out_reg) -- it does not pulse for "a new descriptor
// just arrived". descriptor_controller's CTRL_IDLE, however, is written
// assuming descriptor_valid is exactly that kind of event. This module
// closes the gap by gating descriptor_controller.descriptor_valid with
// dfu.done, which IS a clean one-cycle registered pulse that lands on the
// same cycle descriptor_out_reg updates -- so the AND is a correctly-
// qualified "new descriptor ready" pulse with valid data alongside it.
//
// IMPORTANT
// ---------
//   Does not modify descriptor_memory.sv, descriptor_fetch_unit.sv (besides
//   the bytes_per_element fix noted in that file), descriptor_controller.sv,
//   or scheduler_engine.sv beyond completing its dense/sparse instantiation.
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

import descriptor_pkg::*;
import dma_pkg::*;

module accelerator_top #(

    // NOTE: descriptor_memory's own INIT_FILE/USE_INIT_FILE parameters are
    // intentionally left at their defaults (no file, disabled) here rather
    // than threaded through as accelerator_top parameters: this milestone
    // preloads descriptors via the exposed cpu_* port instead, and Icarus
    // Verilog (unlike VCS/Questa/Xcelium) cannot bind a `string` parameter
    // passed through more than one level of hierarchy -- confirmed with a
    // 3-line reproduction, not an RTL bug. If you later want file-based
    // descriptor preload, edit descriptor_memory's instantiation below
    // directly rather than re-threading a string parameter through here.
    parameter int NUM_JOBS = 2,
    parameter bit VERBOSE  = 1'b0

)(
    input logic clk,
    input logic rst,

    //==========================================================================
    // Top-Level Control
    //==========================================================================

    input  logic run,
    input  logic [DESC_INDEX_WIDTH-1:0] job_index_in,
    output logic all_done,
    output logic any_error,

    //==========================================================================
    // CPU Preload Interface (Descriptor Memory)
    //
    // Exposed so a testbench (or, eventually, a real driver/compiler) can
    // author descriptors before `run` is pulsed.
    //==========================================================================

    input  logic                          cpu_we,
    input  logic [DESC_INDEX_WIDTH-1:0]   cpu_desc_idx,
    input  logic [WORD_COUNTER_WIDTH-1:0] cpu_word_offset,
    input  descriptor_mem_word_t          cpu_wdata,

    //==========================================================================
    // Result Observation (pass-through from scheduler_engine)
    //==========================================================================

    output logic              debug_dense_result_valid,
    output logic [15:0]       debug_dense_result_row,
    output logic [15:0]       debug_dense_result_col,
    output logic signed [63:0] debug_dense_result_data,
    output logic [31:0]       debug_dense_mac_count,

    output logic signed [63:0] debug_sparse_result [0:7][0:7],
    output logic [31:0]        debug_sparse_mac_count,

    //==========================================================================
    // Indexed Single-Element Read (for FMAC_READ) -- pass-through to
    // scheduler_engine's result_read_index/result_read_data. See that
    // module for why this exists instead of exposing the arrays/streams
    // directly (Icarus 2D-unpacked-array-port propagation bug).
    //==========================================================================

    input  logic [5:0]         result_read_index_in,
    output logic signed [63:0] result_read_data_out,

    output logic [DESC_INDEX_WIDTH-1:0] debug_current_job_index,
    output job_status_t                 debug_job_status,
    output logic                        desc_fetch_busy
);

    //==========================================================================
    // Descriptor Memory
    //==========================================================================

    logic                     dfu_re;
    logic [DESC_INDEX_WIDTH-1:0] dfu_desc_idx;
    logic [WORD_COUNTER_WIDTH-1:0] dfu_word_offset;
    descriptor_mem_word_t     dfu_rdata;

    descriptor_memory u_descriptor_memory (

        .clk (clk),

        // CPU preload port
        .cpu_re          (1'b0),
        .cpu_we          (cpu_we),
        .cpu_desc_idx    (cpu_desc_idx),
        .cpu_word_offset (cpu_word_offset),
        .cpu_wdata       (cpu_wdata),
        .cpu_rdata       (),

        // DFU port
        .dfu_re          (dfu_re),
        .dfu_desc_idx    (dfu_desc_idx),
        .dfu_word_offset (dfu_word_offset),
        .dfu_rdata       (dfu_rdata)
    );

    //==========================================================================
    // Descriptor Fetch Unit
    //==========================================================================

    logic                        dfu_start;
    logic [DESC_INDEX_WIDTH-1:0] job_index;

    logic        dfu_busy;
    logic        dfu_done;
    descriptor_t dfu_descriptor_out;
    logic        dfu_descriptor_valid;
    logic        dfu_descriptor_error;
    logic [3:0]  dfu_descriptor_error_code;

    descriptor_fetch_unit u_descriptor_fetch_unit (

        .clk (clk),
        .rst (rst),

        .start            (dfu_start),
        .descriptor_index (job_index),

        .dfu_re          (dfu_re),
        .dfu_desc_idx    (dfu_desc_idx),
        .dfu_word_offset (dfu_word_offset),
        .dfu_rdata       (dfu_rdata),

        .busy (dfu_busy),
        .done (dfu_done),

        .descriptor_out         (dfu_descriptor_out),
        .descriptor_valid       (dfu_descriptor_valid),
        .descriptor_error       (dfu_descriptor_error),
        .descriptor_error_code  (dfu_descriptor_error_code)
    );

    //==========================================================================
    // Descriptor Controller
    //
    // descriptor_valid is gated by dfu_done here -- see header comment.
    //==========================================================================

    logic                      controller_scheduler_start;
    scheduler_mode_t           controller_scheduler_mode;
    descriptor_t               controller_descriptor_out;

    logic scheduler_busy_w;
    logic scheduler_done_w;
    logic scheduler_error_w;

    job_status_t job_status_w;

    logic fetch_next_descriptor;
    logic controller_busy;
    logic controller_done;
    logic controller_error;

    descriptor_controller u_descriptor_controller (

        .clk (clk),
        .rst (rst),

        .descriptor_in          (dfu_descriptor_out),
        .descriptor_valid       (dfu_done),
        .descriptor_error       (dfu_descriptor_error),
        .descriptor_error_code  (descriptor_error_t'(dfu_descriptor_error_code)),

        .fetch_next_descriptor (fetch_next_descriptor),

        .scheduler_start (controller_scheduler_start),
        .scheduler_mode  (controller_scheduler_mode),
        .descriptor_out  (controller_descriptor_out),

        .scheduler_busy (scheduler_busy_w),
        .scheduler_done (scheduler_done_w),
        .scheduler_error(scheduler_error_w),

        .job_status (job_status_w),

        .controller_busy  (controller_busy),
        .controller_done  (controller_done),
        .controller_error (controller_error)
    );

    //==========================================================================
    // Scheduler Engine (Dense / Sparse Dispatch)
    //==========================================================================

    scheduler_engine #(
        .VERBOSE (VERBOSE)
    ) u_scheduler_engine (

        .clk (clk),
        .rst (rst),

        .scheduler_start (controller_scheduler_start),
        .scheduler_mode  (controller_scheduler_mode),
        .descriptor_in   (controller_descriptor_out),

        .scheduler_busy  (scheduler_busy_w),
        .scheduler_done  (scheduler_done_w),
        .scheduler_error (scheduler_error_w),

        .debug_dense_result_valid (debug_dense_result_valid),
        .debug_dense_result_row   (debug_dense_result_row),
        .debug_dense_result_col   (debug_dense_result_col),
        .debug_dense_result_data  (debug_dense_result_data),
        .debug_dense_mac_count    (debug_dense_mac_count),

        .debug_sparse_result    (debug_sparse_result),
        .debug_sparse_mac_count (debug_sparse_mac_count),

        .result_read_index (result_read_index_in),
        .result_read_data  (result_read_data_out)
    );

    //==========================================================================
    // Top-Level Job Sequencer
    //
    // CPU-integration interface: run exactly ONE job, at whatever index
    // job_index_in carries, per `run` pulse -- then return to TOP_IDLE and
    // pulse all_done for exactly one cycle, ready for the next `run`
    // immediately (no reset needed between jobs). This replaces the old
    // "walk 0..NUM_JOBS-1 then freeze forever" behavior, which suited a
    // fixed-sequence testbench but not a CPU that wants to pick which
    // descriptor to run each time (FMAC_SETDESC + FMAC_START).
    //
    // any_error is now per-job (cleared at the start of each new run),
    // not sticky across the module's whole lifetime -- a CPU polling
    // after each dispatch wants "did THIS job fail", not "has any job
    // ever failed since reset".
    //==========================================================================

    typedef enum logic [2:0] {

        TOP_IDLE,
        TOP_FETCH,
        TOP_WAIT_FETCH,
        TOP_WAIT_JOB,
        TOP_DONE

    } top_state_t;

    top_state_t top_state, top_next;

    logic any_error_reg;

    always_ff @(posedge clk) begin

        if (rst)
            top_state <= TOP_IDLE;
        else
            top_state <= top_next;

    end

    always_ff @(posedge clk) begin

        if (rst)
            job_index <= '0;
        else if (top_state == TOP_IDLE && run)
            job_index <= job_index_in;

    end

    always_ff @(posedge clk) begin

        if (rst)
            any_error_reg <= 1'b0;
        else if (top_state == TOP_IDLE && run)
            any_error_reg <= 1'b0;
        else if (top_state == TOP_WAIT_JOB && controller_error)
            any_error_reg <= 1'b1;

    end

    always_comb begin

        top_next = top_state;

        case (top_state)

            TOP_IDLE:
                if (run)
                    top_next = TOP_FETCH;

            TOP_FETCH:
                top_next = TOP_WAIT_FETCH;

            TOP_WAIT_FETCH:
                if (dfu_done)
                    top_next = TOP_WAIT_JOB;

            TOP_WAIT_JOB:
                if (controller_done || controller_error)
                    top_next = TOP_DONE;

            TOP_DONE:
                top_next = TOP_IDLE;

            default:
                top_next = TOP_IDLE;

        endcase

    end

    assign dfu_start = (top_state == TOP_FETCH);
    assign all_done  = (top_state == TOP_DONE);
    assign desc_fetch_busy = (top_state == TOP_FETCH) || (top_state == TOP_WAIT_FETCH);
    assign any_error = any_error_reg;

    assign debug_current_job_index = job_index;
    assign debug_job_status        = job_status_w;

endmodule

`default_nettype wire