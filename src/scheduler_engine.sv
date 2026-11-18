/******************************************************************************
 *
 * Module      : scheduler_engine
 *
 * Description :
 *      Central execution controller for the Intelligent DMA.
 *
 *      Responsibilities:
 *   - Receive execution request from Descriptor Controller
 *   - Select Dense or Sparse Scheduler
 *   - Start selected Scheduler
 *   - Monitor scheduler execution
 *   - Report completion/error back to Descriptor Controller
 ******************************************************************************/

`timescale 1ns/1ps

import descriptor_pkg::*;
import dma_pkg::*;

module scheduler_engine
#(
    parameter bit VERBOSE = 1'b0
)
(
    //----------------------------------------------------------
    // Global Signals
    //----------------------------------------------------------

    input logic clk,
    input logic rst,

    //----------------------------------------------------------
    // Descriptor Controller Interface
    //----------------------------------------------------------

    input logic scheduler_start,

    input scheduler_mode_t scheduler_mode,

    input descriptor_t descriptor_in,

    //----------------------------------------------------------
    // Status Outputs
    //----------------------------------------------------------

    output logic scheduler_busy,

    output logic scheduler_done,

    output logic scheduler_error,

    //----------------------------------------------------------
    // Dense Result Observation (pass-through)
    //----------------------------------------------------------

    output logic              debug_dense_result_valid,
    output logic [15:0]       debug_dense_result_row,
    output logic [15:0]       debug_dense_result_col,
    output logic signed [63:0] debug_dense_result_data,
    output logic [31:0]       debug_dense_mac_count,

    //----------------------------------------------------------
    // Sparse Result Observation (pass-through)
    //----------------------------------------------------------

    output logic signed [63:0] debug_sparse_result [0:7][0:7],
    output logic [31:0]        debug_sparse_mac_count,

    //----------------------------------------------------------
    // Indexed Single-Element Read (for FMAC_READ)
    //
    // debug_sparse_result above is a live 8x8 array output -- crossing it
    // through another port boundary (accelerator_top, then riscv_pipeline)
    // hits the same Icarus 2D-unpacked-array-port propagation bug the
    // testbench already worked around with a hierarchical ref (see
    // accelerator_top_tb.sv). Dense has the opposite problem: it's a
    // one-shot valid/row/col/data STREAM with nothing to index after the
    // fact. This port solves both: read_index selects one flat element
    // (row=index[5:3], col=index[2:0]) from whichever mode this job
    // actually ran -- sparse read straight off the live array, dense read
    // off a small buffer captured here as debug_dense_result_valid pulses
    // by during the job. Only a single 64-bit scalar ever crosses a port
    // boundary -- never the array itself.
    //----------------------------------------------------------

    input  logic [5:0]         result_read_index,
    output logic signed [63:0] result_read_data

);

//----------------------------------------------------------
// Scheduler Engine FSM States
//----------------------------------------------------------

typedef enum logic [2:0]
{
    SCHED_IDLE,

    SCHED_SELECT,

    SCHED_START,

    SCHED_WAIT,

    SCHED_COMPLETE,

    SCHED_ERROR

} scheduler_state_t;

//----------------------------------------------------------
// Internal Registers
//----------------------------------------------------------

scheduler_state_t current_state;
scheduler_state_t next_state;

descriptor_t descriptor_reg;

scheduler_mode_t active_scheduler;

//----------------------------------------------------------
// Dense Scheduler Interface
//----------------------------------------------------------

logic dense_start;

logic dense_busy;

logic dense_done;

logic dense_error;

//----------------------------------------------------------
// Sparse Scheduler Interface
//----------------------------------------------------------

logic sparse_start;

logic sparse_busy;

logic sparse_done;

logic sparse_error;

//----------------------------------------------------------
// Dense / Sparse Subsystem Instances
//
// dense_subsystem_wrapper and sparse_subsystem_wrapper are each
// self-contained (own transfer engine + own private memory model),
// so dispatch here is just: latch the descriptor, pulse the selected
// subsystem's start, wait for its done pulse. Neither subsystem
// exposes an error output today, so *_error stays tied low -- there
// is no timeout/error detection at this level yet. That is a gap
// worth closing before this runs unattended.
//----------------------------------------------------------

assign dense_error  = 1'b0;
assign sparse_error = 1'b0;

dense_subsystem_wrapper #(
    .VERBOSE (VERBOSE)
) u_dense_subsystem (

    .clk (clk),
    .rst (rst),

    .start      (dense_start),
    .descriptor (descriptor_reg),

    .dense_done (dense_done),

    .transfer_busy (),
    .transfer_done (),

    .debug_spad_bank         (),
    .debug_spad_address      (),
    .debug_spad_write_data   (),
    .debug_spad_write_enable (),

    .debug_compute_result_valid (debug_dense_result_valid),
    .debug_compute_result_row   (debug_dense_result_row),
    .debug_compute_result_col   (debug_dense_result_col),
    .debug_compute_result_data  (debug_dense_result_data),

    .debug_compute_cycle_count  (),
    .debug_compute_a_read_count (),
    .debug_compute_b_read_count (),
    .debug_compute_mac_count    (debug_dense_mac_count),
    .debug_compute_output_count ()
);

assign dense_busy = ~dense_done;

sparse_subsystem_wrapper #(
    .VERBOSE (VERBOSE)
) u_sparse_subsystem (

    .clk (clk),
    .rst (rst),

    .start      (sparse_start),
    .descriptor (descriptor_reg),

    .sparse_done (sparse_done),

    .transfer_busy (),
    .transfer_done (),

    .debug_compute_result     (debug_sparse_result),
    .debug_compute_mac_count  (debug_sparse_mac_count)
);

assign sparse_busy = ~sparse_done;

//----------------------------------------------------------
// Indexed Single-Element Read (for FMAC_READ) -- see port comment above
//----------------------------------------------------------

// active_scheduler is latched at SCHED_SELECT and only changes at the next
// job's SCHED_SELECT, so this stays valid for the whole job, exactly the
// window a CPU-side accel_done_reg would gate a read to.
wire job_is_sparse = (active_scheduler != SCHEDULER_DENSE);

// Dense has no storage of its own -- debug_dense_result_valid/row/col/data
// is a one-shot stream, gone the cycle after it pulses. Capture it here so
// there's something to index into after the job finishes. Sized for the
// current fixed 8x8 tile; row/col truncated to [2:0] on that assumption.
logic signed [63:0] dense_result_buf [0:7][0:7];

always_ff @(posedge clk) begin
    if (debug_dense_result_valid)
        dense_result_buf[debug_dense_result_row[2:0]][debug_dense_result_col[2:0]]
            <= debug_dense_result_data;
end

wire [2:0] result_read_row = result_read_index[5:3];
wire [2:0] result_read_col = result_read_index[2:0];

// Sparse source array. debug_sparse_result is a port arriving from
// sparse_subsystem_wrapper -- exactly the one-boundary 2D-unpacked-array
// hop Icarus fails to propagate. Under Icarus only, read the leaf array
// by hierarchical path instead (same path accelerator_top_tb.sv uses);
// every other tool takes the clean port path. Proper fix is to push this
// index mux down into sparse_subsystem_wrapper/sparse_datapath so no
// array ever crosses a port -- needs those files.
`ifdef __ICARUS__
wire signed [63:0] sparse_elem =
    u_sparse_subsystem.u_sparse_datapath.u_sparse_compute_8x8.result[result_read_row][result_read_col];
`else
wire signed [63:0] sparse_elem = debug_sparse_result[result_read_row][result_read_col];
`endif

assign result_read_data = job_is_sparse
    ? sparse_elem
    : dense_result_buf[result_read_row][result_read_col];

//----------------------------------------------------------
// State Register
//----------------------------------------------------------

always_ff @(posedge clk)
begin

    if (rst)
    begin

        current_state <= SCHED_IDLE;

    end

    else
    begin

        current_state <= next_state;

    end

end

//----------------------------------------------------------
// Descriptor Register
//----------------------------------------------------------

always_ff @(posedge clk)
begin

    if (rst)
    begin

        descriptor_reg <= '0;

    end

    else if (current_state == SCHED_SELECT)
    begin

        descriptor_reg <= descriptor_in;

    end

end

//----------------------------------------------------------
// Selected Scheduler Register
//----------------------------------------------------------

always_ff @(posedge clk)
begin

    if (rst)
    begin

        active_scheduler <= SCHEDULER_DENSE;

    end

    else if (current_state == SCHED_SELECT)
    begin

        active_scheduler <= scheduler_mode;

    end

end

//----------------------------------------------------------
// Next-State Logic
//----------------------------------------------------------

always_comb
begin

    //------------------------------------------------------
    // Default
    //------------------------------------------------------

    next_state = current_state;

    case (current_state)

        //--------------------------------------------------
        // Wait for Descriptor Controller
        //--------------------------------------------------

        SCHED_IDLE:
        begin

            if (scheduler_start)
            begin

                next_state = SCHED_SELECT;

            end

        end

        //--------------------------------------------------
        // Select Dense/Sparse Scheduler
        //--------------------------------------------------

        SCHED_SELECT:
        begin

            next_state = SCHED_START;

        end

        //--------------------------------------------------
        // Generate Start Pulse
        //--------------------------------------------------

        SCHED_START:
        begin

            next_state = SCHED_WAIT;

        end

        //--------------------------------------------------
        // Wait for Scheduler Completion
        //--------------------------------------------------

        SCHED_WAIT:
        begin

            if (active_scheduler == SCHEDULER_DENSE)
            begin

            if (dense_error)
                next_state = SCHED_ERROR;

            else if (dense_done)
                next_state = SCHED_COMPLETE;

        end

            else
        begin

            if (sparse_error)
                next_state = SCHED_ERROR;

            else if (sparse_done)
                next_state = SCHED_COMPLETE;

        end

        end

        //--------------------------------------------------
        // Job Finished
        //--------------------------------------------------

        SCHED_COMPLETE:
        begin

            next_state = SCHED_IDLE;

        end

        //--------------------------------------------------
        // Job Failed
        //--------------------------------------------------

        SCHED_ERROR:
        begin

            next_state = SCHED_IDLE;

        end

        //--------------------------------------------------
        // Safety
        //--------------------------------------------------

        default:
        begin

            next_state = SCHED_IDLE;

        end

    endcase

end

//----------------------------------------------------------
// Output Logic
//----------------------------------------------------------

always_comb
begin

    //------------------------------------------------------
    // Default Outputs
    //------------------------------------------------------

    scheduler_busy  = 1'b0;
    scheduler_done  = 1'b0;
    scheduler_error = 1'b0;

    dense_start  = 1'b0;
    sparse_start = 1'b0;

    case (current_state)

        //--------------------------------------------------
        // Idle
        //--------------------------------------------------

        SCHED_IDLE:
        begin

            // Default outputs already assigned

        end

        //--------------------------------------------------
        // Select Scheduler
        //--------------------------------------------------

        SCHED_SELECT:
        begin

            scheduler_busy = 1'b1;

        end

        //--------------------------------------------------
        // Generate One-Cycle Start Pulse
        //--------------------------------------------------

        SCHED_START:
        begin

            scheduler_busy = 1'b1;

            if (active_scheduler == SCHEDULER_DENSE)
                dense_start = 1'b1;
            else
                sparse_start = 1'b1;

        end

        //--------------------------------------------------
        // Wait for Scheduler
        //--------------------------------------------------

        SCHED_WAIT:
        begin

            scheduler_busy = 1'b1;

        end

        //--------------------------------------------------
        // Completed
        //--------------------------------------------------

        SCHED_COMPLETE:
        begin

            scheduler_done = 1'b1;

        end

        //--------------------------------------------------
        // Error
        //--------------------------------------------------

        SCHED_ERROR:
        begin

            scheduler_error = 1'b1;

        end

        default:
        begin

            // Default outputs already assigned

        end

    endcase

end

endmodule