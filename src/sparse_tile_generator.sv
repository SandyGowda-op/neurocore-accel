//==============================================================================
// Module      : sparse_tile_generator
//
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   Generates a sparse tile transfer request from the
//   current tile context and descriptor.
//
// Responsibilities:
//   - Compute compressed A value address
//   - Compute B value address
//   - Compute metadata address
//   - Compute destination address
//   - Compute edge tile dimensions
//   - Compute compressed A transfer size
//   - Compute B transfer size
//   - Compute metadata transfer size
//   - Populate sparse_tile_request_t
//
// Sparse format:
//   NVIDIA-style 2:4 structured sparsity.
//
//   For every group of 4 A elements:
//       2 values are stored
//       1 metadata byte describes their positions
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

import descriptor_pkg::*;
import tile_pkg::*;

module sparse_tile_generator
(
    //--------------------------------------------------------------------------
    // Inputs
    //--------------------------------------------------------------------------

    input descriptor_t descriptor,

    input tile_context_t current_tile,

    //--------------------------------------------------------------------------
    // Number of tile blocks along K dimension
    //--------------------------------------------------------------------------

    input logic [15:0] num_k_tiles,

    input logic last_tile,

    //--------------------------------------------------------------------------
    // Output
    //--------------------------------------------------------------------------

    output sparse_tile_request_t sparse_tile_request

);

    //==========================================================================
    // Remaining Tile Dimensions
    //==========================================================================

    logic [15:0] remaining_rows;
    logic [15:0] remaining_cols;
    logic [15:0] remaining_k;


    //==========================================================================
    // Address Offsets
    //==========================================================================

    logic [31:0] value_row_offset_a;
    logic [31:0] value_col_offset_a;

    logic [31:0] value_row_offset_b;
    logic [31:0] value_col_offset_b;

    logic [31:0] dest_row_offset;
    logic [31:0] dest_col_offset;

    logic [31:0] metadata_tile_offset;


    //==========================================================================
    // Sparse Metadata Organization
    //==========================================================================
    //
    // 2:4 sparsity:
    //
    //       4 original A elements
    //               |
    //               +----> 2 stored values
    //               |
    //               +----> 1 metadata byte
    //
    // Therefore:
    //
    //       GROUP_SIZE = 4
    //
    //       VALUES_PER_GROUP = 2
    //
    //       METADATA_BYTES_PER_GROUP = 1
    //
    // For a complete 8x8 A tile:
    //
    //       64 original elements
    //       32 stored values
    //       16 metadata bytes
    //
    //==========================================================================

    localparam int GROUP_SIZE = 4;

    localparam int VALUES_PER_GROUP = 2;

    localparam int METADATA_BYTES_PER_GROUP = 1;

    // Scratchpad word width in bytes. Metadata is stored one group per
    // scratchpad word (SPAD_DATA_WIDTH=32 in the rest of the design),
    // not packed 1-byte-per-group -- see note at metadata_transfer_bytes.
    localparam int METADATA_WORD_BYTES = 4;

    localparam int METADATA_BYTES_PER_TILE =
        (TILE_M * TILE_K) / GROUP_SIZE;


    //==========================================================================
    // Sparse Tile Generation Logic
    //==========================================================================

    always_comb
    begin

        //======================================================================
        // Defaults
        //======================================================================

        sparse_tile_request = '0;

        remaining_rows = '0;
        remaining_cols = '0;
        remaining_k    = '0;

        value_row_offset_a = '0;
        value_col_offset_a = '0;

        value_row_offset_b = '0;
        value_col_offset_b = '0;

        dest_row_offset = '0;
        dest_col_offset = '0;

        metadata_tile_offset = '0;


        //======================================================================
        // Remaining Matrix Dimensions
        //======================================================================

        //----------------------------------------------------------------------
        // Rows
        //----------------------------------------------------------------------

        if ((current_tile.tile_row * TILE_M) >= descriptor.rows)

            remaining_rows = 16'd0;

        else

            remaining_rows =
                descriptor.rows -
                (current_tile.tile_row * TILE_M);


        //----------------------------------------------------------------------
        // Columns
        //----------------------------------------------------------------------

        if ((current_tile.tile_col * TILE_N) >= descriptor.cols)

            remaining_cols = 16'd0;

        else

            remaining_cols =
                descriptor.cols -
                (current_tile.tile_col * TILE_N);


        //----------------------------------------------------------------------
        // K
        //----------------------------------------------------------------------

        if ((current_tile.tile_k * TILE_K) >= descriptor.k)

            remaining_k = 16'd0;

        else

            remaining_k =
                descriptor.k -
                (current_tile.tile_k * TILE_K);


        //======================================================================
        // Compressed A Address
        //======================================================================
        //
        // The sparse A values are assumed to be stored contiguously in
        // compressed form.
        //
        // Tile selection still follows the logical matrix tile coordinates.
        //
        // The transfer size determines how many compressed values are read.
        //
        //======================================================================

        value_row_offset_a =
            current_tile.tile_row *
            TILE_M *
            descriptor.strideA;

        value_col_offset_a =
            current_tile.tile_k *
            TILE_K *
            descriptor.bytes_per_element;

        sparse_tile_request.values_addr_a =
            descriptor.srcA_addr +
            value_row_offset_a +
            value_col_offset_a;


        //======================================================================
        // B Address
        //======================================================================
        //
        // B remains dense.
        //
        // B[k][j] =
        //     base_B +
        //     k * stride_B +
        //     j
        //
        //======================================================================

        value_row_offset_b =
            current_tile.tile_k *
            TILE_K *
            descriptor.strideB;

        value_col_offset_b =
            current_tile.tile_col *
            TILE_N *
            descriptor.bytes_per_element;

        sparse_tile_request.values_addr_b =
            descriptor.srcB_addr +
            value_row_offset_b +
            value_col_offset_b;


        //======================================================================
        // Destination C Address
        //======================================================================

        dest_row_offset =
            current_tile.tile_row *
            TILE_M *
            descriptor.strideC;

        dest_col_offset =
            current_tile.tile_col *
            TILE_N *
            descriptor.bytes_per_element;

        sparse_tile_request.addr_c =
            descriptor.dst_addr +
            dest_row_offset +
            dest_col_offset;


        //======================================================================
        // Metadata Address
        //======================================================================
        //
        // Metadata is organized one tile after another:
        //
        //     Tile(row=0,k=0)
        //     Tile(row=0,k=1)
        //     ...
        //     Tile(row=1,k=0)
        //     Tile(row=1,k=1)
        //     ...
        //
        // Metadata does not depend on tile_col because the metadata describes
        // the A matrix, whose dimensions are M x K.
        //
        // Tile index:
        //
        //     tile_row * num_k_tiles + tile_k
        //
        //======================================================================

        metadata_tile_offset =
            (
                (current_tile.tile_row * num_k_tiles)
                +
                current_tile.tile_k
            )
            *
            METADATA_BYTES_PER_TILE;

        sparse_tile_request.metadata_addr_a =
            descriptor.metadata_addr +
            metadata_tile_offset;


        //======================================================================
        // Tile Dimensions
        //======================================================================

        //----------------------------------------------------------------------
        // Rows
        //----------------------------------------------------------------------

        if (remaining_rows >= TILE_M)

            sparse_tile_request.rows = TILE_M;

        else

            sparse_tile_request.rows = remaining_rows;


        //----------------------------------------------------------------------
        // Columns
        //----------------------------------------------------------------------

        if (remaining_cols >= TILE_N)

            sparse_tile_request.cols = TILE_N;

        else

            sparse_tile_request.cols = remaining_cols;


        //----------------------------------------------------------------------
        // K
        //----------------------------------------------------------------------

        if (remaining_k >= TILE_K)

            sparse_tile_request.k_size = TILE_K;

        else

            sparse_tile_request.k_size = remaining_k;


        //======================================================================
        // Transfer Sizes
        //======================================================================
        //
        // A is stored using 2:4 structured sparsity.
        //
        // For every 4 logical elements:
        //
        //     2 values are stored.
        //
        // Therefore:
        //
        //     compressed_A_elements =
        //         (rows * k_size) / 2
        //
        // B remains dense:
        //
        //     B_elements =
        //         k_size * cols
        //
        // Metadata:
        //
        //     metadata_groups =
        //         (rows * k_size) / 4
        //
        // Each group's metadata occupies one full scratchpad word (the
        // scratchpad/compute path stores each metadata entry at
        // SPAD_DATA_WIDTH=32 bits, same as A/B, not packed 1-byte-per-
        // group) -- confirmed by tracing this generator end-to-end for
        // the first time: with the un-multiplied formula, only the first
        // rows*k_size/16 metadata WORDS actually got transferred (16 of
        // the 64 bytes a full 8x8 tile needs), leaving the rest of that
        // scratchpad bank uninitialized and poisoning every MAC that
        // touched it with X. METADATA_WORD_BYTES is the scratchpad's
        // fixed word width in bytes -- a hardware property, not
        // descriptor.bytes_per_element (which describes the A/B/C matrix
        // element width and is a separate, per-descriptor knob).
        //
        //======================================================================

        sparse_tile_request.transfer_bytes_a =
            (
                sparse_tile_request.rows *
                sparse_tile_request.k_size *
                VALUES_PER_GROUP
            )
            /
            GROUP_SIZE
            *
            descriptor.bytes_per_element;


        sparse_tile_request.transfer_bytes_b =
            sparse_tile_request.k_size *
            sparse_tile_request.cols *
            descriptor.bytes_per_element;


        sparse_tile_request.metadata_transfer_bytes =
            (
                sparse_tile_request.rows *
                sparse_tile_request.k_size
            )
            /
            GROUP_SIZE *
            METADATA_BYTES_PER_GROUP *
            METADATA_WORD_BYTES;


        //======================================================================
        // Tile Context
        //======================================================================

        sparse_tile_request.tile_context =
            current_tile;


        //======================================================================
        // Control
        //======================================================================

        sparse_tile_request.valid =
            1'b1;

        sparse_tile_request.last_tile =
            last_tile;


        //======================================================================
        // Scratchpad Banks
        //======================================================================
        //
        // Bank A:
        //     Compressed A values
        //
        // Bank B:
        //     Dense B values
        //
        // Bank C:
        //     Sparse metadata
        //
        //======================================================================

        sparse_tile_request.bank_a =
            4'd0;

        sparse_tile_request.bank_b =
            4'd1;

        sparse_tile_request.bank_c =
            4'd2;

        sparse_tile_request.metadata_bank =
            4'd2;

    end

endmodule

`default_nettype wire