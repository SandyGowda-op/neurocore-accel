//==============================================================================
// Module      : scratchpad
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   Top-level scratchpad memory subsystem.
//
//   Instantiates three scratchpad memory banks and provides:
//
//     1. DMA access
//     2. Existing dense compute access
//     3. Sparse compute access
//
//   Dense path is preserved through the original compute interface.
//
//   Sparse path provides independent access to:
//
//       Bank A -> compressed A values
//       Bank B -> dense B values
//       Bank C -> sparse metadata
//
//   Dense and sparse compute paths are mutually exclusive.
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module scratchpad #(

    parameter int DATA_WIDTH = 32,
    parameter int MATRIX_DIM = 8,
    parameter int DEPTH      = MATRIX_DIM * MATRIX_DIM,
    parameter int ADDR_WIDTH = $clog2(DEPTH)

)(

    input logic clk,
    input logic rst,

    //======================================================================
    // DMA Interface
    //======================================================================

    input  logic [1:0]             dma_bank_sel,
    input logic                    dma_en,
    input logic                    dma_we,
    input logic [ADDR_WIDTH-1:0]   dma_addr,
    input logic [DATA_WIDTH-1:0]   dma_wdata,
    output logic [DATA_WIDTH-1:0]  dma_rdata,

    //======================================================================
    // Existing Dense Compute Interface
    //
    // IMPORTANT:
    // This interface is preserved for the verified dense datapath.
    //======================================================================

    input  logic [1:0]             compute_bank_sel,
    input logic                    compute_en,
    input logic                    compute_we,
    input logic [ADDR_WIDTH-1:0]   compute_addr,
    input logic [DATA_WIDTH-1:0]   compute_wdata,
    output logic [DATA_WIDTH-1:0]  compute_rdata,

    //======================================================================
    // Sparse Compute Interface
    //
    // Sparse execution requires three independent logical accesses:
    //
    //   sparse A       -> compressed A values
    //   sparse B       -> dense B values
    //   sparse metadata -> 2:4 metadata
    //
    // These are mapped to Banks A, B and C respectively.
    //======================================================================

    // Sparse A
    input  logic                    sparse_a_en,
    input  logic                    sparse_a_we,
    input  logic [ADDR_WIDTH-1:0]   sparse_a_addr,
    input  logic [DATA_WIDTH-1:0]   sparse_a_wdata,
    output logic [DATA_WIDTH-1:0]   sparse_a_rdata,

    // Sparse B
    input  logic                    sparse_b_en,
    input  logic                    sparse_b_we,
    input  logic [ADDR_WIDTH-1:0]   sparse_b_addr,
    input  logic [DATA_WIDTH-1:0]   sparse_b_wdata,
    output logic [DATA_WIDTH-1:0]   sparse_b_rdata,

    // Sparse metadata
    input  logic                    sparse_metadata_en,
    input  logic                    sparse_metadata_we,
    input  logic [ADDR_WIDTH-1:0]   sparse_metadata_addr,
    input  logic [DATA_WIDTH-1:0]   sparse_metadata_wdata,
    output logic [DATA_WIDTH-1:0]   sparse_metadata_rdata

);

//==============================================================================
// Internal Signals
//==============================================================================

//------------------------------------------------------------------------------
// DMA read data
//------------------------------------------------------------------------------

logic [DATA_WIDTH-1:0] dma_rdata_bank_a;
logic [DATA_WIDTH-1:0] dma_rdata_bank_b;
logic [DATA_WIDTH-1:0] dma_rdata_bank_c;

//------------------------------------------------------------------------------
// Dense compute read data
//------------------------------------------------------------------------------

logic [DATA_WIDTH-1:0] compute_rdata_bank_a;
logic [DATA_WIDTH-1:0] compute_rdata_bank_b;
logic [DATA_WIDTH-1:0] compute_rdata_bank_c;

//------------------------------------------------------------------------------
// Sparse compute read data
//------------------------------------------------------------------------------

logic [DATA_WIDTH-1:0] sparse_a_rdata_bank;
logic [DATA_WIDTH-1:0] sparse_b_rdata_bank;
logic [DATA_WIDTH-1:0] sparse_metadata_rdata_bank;

//==============================================================================
// DMA Enables
//==============================================================================

logic dma_en_bank_a;
logic dma_en_bank_b;
logic dma_en_bank_c;

//==============================================================================
// Dense Compute Enables
//==============================================================================

logic compute_en_bank_a;
logic compute_en_bank_b;
logic compute_en_bank_c;

//==============================================================================
// Sparse Compute Enables
//==============================================================================

logic sparse_en_bank_a;
logic sparse_en_bank_b;
logic sparse_en_bank_c;

//==============================================================================
// Selected Compute Signals Per Bank
//
// A bank has only one compute port.
//
// Therefore the physical compute port is selected between:
//
//     Dense compute
//     Sparse compute
//
// Dense has priority only when sparse is not accessing that bank.
//
// Dense and sparse execution are expected to be mutually exclusive.
//==============================================================================

logic                    bank_a_compute_en;
logic                    bank_a_compute_we;
logic [ADDR_WIDTH-1:0]   bank_a_compute_addr;
logic [DATA_WIDTH-1:0]   bank_a_compute_wdata;

logic                    bank_b_compute_en;
logic                    bank_b_compute_we;
logic [ADDR_WIDTH-1:0]   bank_b_compute_addr;
logic [DATA_WIDTH-1:0]   bank_b_compute_wdata;

logic                    bank_c_compute_en;
logic                    bank_c_compute_we;
logic [ADDR_WIDTH-1:0]   bank_c_compute_addr;
logic [DATA_WIDTH-1:0]   bank_c_compute_wdata;

//==============================================================================
// Bank Select Decode
//==============================================================================

always_comb begin

    //--------------------------------------------------------------------------
    // Defaults
    //--------------------------------------------------------------------------

    dma_en_bank_a = 1'b0;
    dma_en_bank_b = 1'b0;
    dma_en_bank_c = 1'b0;

    compute_en_bank_a = 1'b0;
    compute_en_bank_b = 1'b0;
    compute_en_bank_c = 1'b0;

    sparse_en_bank_a = 1'b0;
    sparse_en_bank_b = 1'b0;
    sparse_en_bank_c = 1'b0;

    //--------------------------------------------------------------------------
    // DMA Decode
    //--------------------------------------------------------------------------

    if (dma_en) begin

        case (dma_bank_sel)

            2'b00:
                dma_en_bank_a = 1'b1;

            2'b01:
                dma_en_bank_b = 1'b1;

            2'b10:
                dma_en_bank_c = 1'b1;

            default:
                ;

        endcase

    end

    //--------------------------------------------------------------------------
    // Existing Dense Compute Decode
    //--------------------------------------------------------------------------
    //
    // IMPORTANT:
    // This is unchanged from the original scratchpad architecture.
    //
    //--------------------------------------------------------------------------

    if (compute_en) begin

        case (compute_bank_sel)

            2'b00:
                compute_en_bank_a = 1'b1;

            2'b01:
                compute_en_bank_b = 1'b1;

            2'b10:
                compute_en_bank_c = 1'b1;

            default:
                ;

        endcase

    end

    //--------------------------------------------------------------------------
    // Sparse Compute Decode
    //
    // Sparse channels are already associated with fixed banks:
    //
    //     A        -> Bank A
    //     B        -> Bank B
    //     metadata -> Bank C
    //--------------------------------------------------------------------------

    sparse_en_bank_a = sparse_a_en;
    sparse_en_bank_b = sparse_b_en;
    sparse_en_bank_c = sparse_metadata_en;

end

//==============================================================================
// Compute Port Arbitration
//==============================================================================
//
// Dense and sparse execution are mutually exclusive.
//
// If sparse is active on a bank, that bank's physical compute port is
// connected to the sparse channel.
//
// Otherwise the existing dense compute channel is connected.
//
//==============================================================================

always_comb begin

    //--------------------------------------------------------------------------
    // Defaults
    //--------------------------------------------------------------------------

    bank_a_compute_en    = 1'b0;
    bank_a_compute_we    = 1'b0;
    bank_a_compute_addr  = '0;
    bank_a_compute_wdata = '0;

    bank_b_compute_en    = 1'b0;
    bank_b_compute_we    = 1'b0;
    bank_b_compute_addr  = '0;
    bank_b_compute_wdata = '0;

    bank_c_compute_en    = 1'b0;
    bank_c_compute_we    = 1'b0;
    bank_c_compute_addr  = '0;
    bank_c_compute_wdata = '0;

    //--------------------------------------------------------------------------
    // Bank A
    //--------------------------------------------------------------------------
    //
    // Sparse A takes the bank when active.
    //
    // Otherwise preserve dense behavior.
    //

    if (sparse_en_bank_a) begin

        bank_a_compute_en    = sparse_a_en;
        bank_a_compute_we    = sparse_a_we;
        bank_a_compute_addr  = sparse_a_addr;
        bank_a_compute_wdata = sparse_a_wdata;

    end
    else begin

        bank_a_compute_en    = compute_en_bank_a;
        bank_a_compute_we    = compute_we;
        bank_a_compute_addr  = compute_addr;
        bank_a_compute_wdata = compute_wdata;

    end

    //--------------------------------------------------------------------------
    // Bank B
    //--------------------------------------------------------------------------

    if (sparse_en_bank_b) begin

        bank_b_compute_en    = sparse_b_en;
        bank_b_compute_we    = sparse_b_we;
        bank_b_compute_addr  = sparse_b_addr;
        bank_b_compute_wdata = sparse_b_wdata;

    end
    else begin

        bank_b_compute_en    = compute_en_bank_b;
        bank_b_compute_we    = compute_we;
        bank_b_compute_addr  = compute_addr;
        bank_b_compute_wdata = compute_wdata;

    end

    //--------------------------------------------------------------------------
    // Bank C
    //--------------------------------------------------------------------------

    if (sparse_en_bank_c) begin

        bank_c_compute_en    = sparse_metadata_en;
        bank_c_compute_we    = sparse_metadata_we;
        bank_c_compute_addr  = sparse_metadata_addr;
        bank_c_compute_wdata = sparse_metadata_wdata;

    end
    else begin

        bank_c_compute_en    = compute_en_bank_c;
        bank_c_compute_we    = compute_we;
        bank_c_compute_addr  = compute_addr;
        bank_c_compute_wdata = compute_wdata;

    end

end

//==============================================================================
// Scratchpad Bank A
//==============================================================================

scratchpad_bank #(

    .DATA_WIDTH (DATA_WIDTH),
    .MATRIX_DIM (MATRIX_DIM),
    .DEPTH      (DEPTH),
    .ADDR_WIDTH (ADDR_WIDTH)

) bank_a (

    .clk (clk),
    .rst (rst),

    //--------------------------------------------------------------------------
    // DMA
    //--------------------------------------------------------------------------

    .dma_en    (dma_en_bank_a),
    .dma_we    (dma_we),
    .dma_addr  (dma_addr),
    .dma_wdata (dma_wdata),
    .dma_rdata (dma_rdata_bank_a),

    //--------------------------------------------------------------------------
    // Compute
    //--------------------------------------------------------------------------

    .compute_en    (bank_a_compute_en),
    .compute_we    (bank_a_compute_we),
    .compute_addr  (bank_a_compute_addr),
    .compute_wdata (bank_a_compute_wdata),
    .compute_rdata (compute_rdata_bank_a)

);

//==============================================================================
// Scratchpad Bank B
//==============================================================================

scratchpad_bank #(

    .DATA_WIDTH (DATA_WIDTH),
    .MATRIX_DIM (MATRIX_DIM),
    .DEPTH      (DEPTH),
    .ADDR_WIDTH (ADDR_WIDTH)

) bank_b (

    .clk (clk),
    .rst (rst),

    //--------------------------------------------------------------------------
    // DMA
    //--------------------------------------------------------------------------

    .dma_en    (dma_en_bank_b),
    .dma_we    (dma_we),
    .dma_addr  (dma_addr),
    .dma_wdata (dma_wdata),
    .dma_rdata (dma_rdata_bank_b),

    //--------------------------------------------------------------------------
    // Compute
    //--------------------------------------------------------------------------

    .compute_en    (bank_b_compute_en),
    .compute_we    (bank_b_compute_we),
    .compute_addr  (bank_b_compute_addr),
    .compute_wdata (bank_b_compute_wdata),
    .compute_rdata (compute_rdata_bank_b)

);

//==============================================================================
// Scratchpad Bank C
//==============================================================================

scratchpad_bank #(

    .DATA_WIDTH (DATA_WIDTH),
    .MATRIX_DIM (MATRIX_DIM),
    .DEPTH      (DEPTH),
    .ADDR_WIDTH (ADDR_WIDTH)

) bank_c (

    .clk (clk),
    .rst (rst),

    //--------------------------------------------------------------------------
    // DMA
    //--------------------------------------------------------------------------

    .dma_en    (dma_en_bank_c),
    .dma_we    (dma_we),
    .dma_addr  (dma_addr),
    .dma_wdata (dma_wdata),
    .dma_rdata (dma_rdata_bank_c),

    //--------------------------------------------------------------------------
    // Compute
    //--------------------------------------------------------------------------

    .compute_en    (bank_c_compute_en),
    .compute_we    (bank_c_compute_we),
    .compute_addr  (bank_c_compute_addr),
    .compute_wdata (bank_c_compute_wdata),
    .compute_rdata (compute_rdata_bank_c)

);

//==============================================================================
// Existing Dense Compute Read Data
//==============================================================================
//
// PRESERVED.
//
//==============================================================================

always_comb begin

    case (compute_bank_sel)

        2'b00:
            compute_rdata = compute_rdata_bank_a;

        2'b01:
            compute_rdata = compute_rdata_bank_b;

        2'b10:
            compute_rdata = compute_rdata_bank_c;

        default:
            compute_rdata = '0;

    endcase

end

//==============================================================================
// DMA Read Data Multiplexer
//==============================================================================

always_comb begin

    case (dma_bank_sel)

        2'b00:
            dma_rdata = dma_rdata_bank_a;

        2'b01:
            dma_rdata = dma_rdata_bank_b;

        2'b10:
            dma_rdata = dma_rdata_bank_c;

        default:
            dma_rdata = '0;

    endcase

end

//==============================================================================
// Sparse Read Data
//==============================================================================
//
// Since each sparse channel is permanently associated with one bank,
// there is no bank multiplexer here.
//
//==============================================================================

assign sparse_a_rdata =
    compute_rdata_bank_a;

assign sparse_b_rdata =
    compute_rdata_bank_b;

assign sparse_metadata_rdata =
    compute_rdata_bank_c;

endmodule

`default_nettype wire