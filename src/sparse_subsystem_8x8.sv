`timescale 1ns/1ps
`default_nettype none

import tile_pkg::*;

module sparse_subsystem_8x8 #(
    parameter integer BURST_BYTES     = 128,
    parameter integer DATA_WIDTH      = 64,
    parameter integer SPAD_DATA_WIDTH = 32,
    parameter integer SPAD_ADDR_WIDTH = 6
)(
    input  logic clk,
    input  logic rst,

    // Sparse tile request
    input  sparse_tile_request_t sparse_tile_request,
    input  logic                 sparse_tile_request_valid,
    output logic                 sparse_tile_request_ready,

    // Compute control
    input  logic compute_start,

    output logic compute_busy,
    output logic compute_done,

    output logic signed [63:0] compute_result [0:7][0:7],
    output logic [31:0]        compute_mac_count,

    // Status
    output logic transfer_busy,
    output logic transfer_done,

    output logic datapath_busy,
    output logic datapath_done
);

    //======================================================================
    // Internal main-memory interface
    //======================================================================

    logic        mem_req_valid;
    logic        mem_req_ready;
    logic [31:0] mem_req_addr;
    logic [31:0] mem_req_bytes;

    logic        mem_rvalid;
    logic [63:0] mem_rdata;
    logic        mem_rlast;

    //======================================================================
    // Sparse datapath
    //======================================================================

    sparse_datapath_8x8_wrapper u_sparse (
    .clk(clk),
    .rst(rst),

    .sparse_tile_request(sparse_tile_request),
    .sparse_tile_request_valid(sparse_tile_request_valid),
    .sparse_tile_request_ready(sparse_tile_request_ready),

    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_addr(mem_req_addr),
    .mem_req_bytes(mem_req_bytes),

    .mem_rvalid(mem_rvalid),
    .mem_rdata(mem_rdata),
    .mem_rlast(mem_rlast),

    .compute_start(compute_start),
    .compute_busy(compute_busy),
    .compute_done(compute_done),
    .compute_result(compute_result),
    .compute_mac_count(compute_mac_count),

    .transfer_busy(transfer_busy),
    .transfer_done(transfer_done),
    .datapath_busy(datapath_busy),
    .datapath_done(datapath_done)
);
    //======================================================================
    // External behavioral main memory
    //======================================================================
    //
    // The memory model remains outside the sparse datapath.
    //
    // The sparse datapath therefore behaves as a consumer of external
    // memory rather than containing the memory model itself.
    //
    //======================================================================

    main_memory_model #(
    .MEMORY_INIT_FILE(
        "mem files/sparse_data_memory.mem"
    )
) u_memory (
    .clk(clk),
    .rst(rst),

    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_addr(mem_req_addr),
    .mem_req_bytes(mem_req_bytes),
    .mem_req_write(1'b0),

    .mem_rvalid(mem_rvalid),
    .mem_rdata(mem_rdata),
    .mem_rlast(mem_rlast)
);

endmodule

`default_nettype wire