//==============================================================================
// Package     : tile_pkg
//
// Description :
//   Common package for all tile-based scheduling modules.
//
//   Contains:
//     - Tile configuration
//     - Tile context
//     - Dense tile request
//     - Sparse tile request
//
//==============================================================================

`timescale 1ns/1ps

package tile_pkg;

    //--------------------------------------------------------------------------
    // Tile Configuration
    //--------------------------------------------------------------------------

    localparam int TILE_M = 8;
    localparam int TILE_N = 8;
    localparam int TILE_K = 8;

    //--------------------------------------------------------------------------
    // Tile Context
    //--------------------------------------------------------------------------

    typedef struct packed
    {
        logic [15:0] tile_row;
        logic [15:0] tile_col;
        logic [15:0] tile_k;

    } tile_context_t;


    //==========================================================================
    // Dense Tile Request
    //==========================================================================

    typedef struct packed
    {
        //---------------------------------------------------------------------- 
        // Control
        //----------------------------------------------------------------------

        logic valid;
        logic last_tile;

        //---------------------------------------------------------------------- 
        // Tile Context
        //----------------------------------------------------------------------

        tile_context_t tile_context;

        //---------------------------------------------------------------------- 
        // Matrix Addresses
        //----------------------------------------------------------------------

        logic [31:0] addr_a;
        logic [31:0] addr_b;
        logic [31:0] addr_c;

        //---------------------------------------------------------------------- 
        // Matrix A transfer size
        //----------------------------------------------------------------------

        logic [31:0] transfer_bytes;

        //---------------------------------------------------------------------- 
        // Matrix B transfer size
        //----------------------------------------------------------------------

        logic [31:0] transfer_bytes_b;

        //---------------------------------------------------------------------- 
        // Tile Dimensions
        //----------------------------------------------------------------------

        logic [15:0] rows;
        logic [15:0] cols;
        logic [15:0] k_size;

        //---------------------------------------------------------------------- 
        // Tile Strides
        //----------------------------------------------------------------------

        logic [15:0] stride_a;
        logic [15:0] stride_b;

        //---------------------------------------------------------------------- 
        // Scratchpad Banks
        //----------------------------------------------------------------------

        logic [3:0] bank_a;
        logic [3:0] bank_b;
        logic [3:0] bank_c;

    } tile_request_t;


    //==========================================================================
    // Sparse Tile Request
    //
    // Sparse execution uses:
    //
    //     Bank A -> compressed A values
    //     Bank B -> B values
    //     Bank C -> metadata
    //
    // The transfer engine treats these as independent contiguous transfers.
    // It does NOT interpret the 2:4 sparsity pattern.
    //==========================================================================

    typedef struct packed
    {
        //---------------------------------------------------------------------- 
        // Control
        //----------------------------------------------------------------------

        logic valid;
        logic last_tile;

        //---------------------------------------------------------------------- 
        // Tile Context
        //----------------------------------------------------------------------

        tile_context_t tile_context;

        //---------------------------------------------------------------------- 
        // Matrix Addresses
        //----------------------------------------------------------------------

        // Compressed A values
        logic [31:0] values_addr_a;

        // Dense B values
        logic [31:0] values_addr_b;

        // Sparse metadata
        logic [31:0] metadata_addr_a;

        // Destination C
        logic [31:0] addr_c;

        //---------------------------------------------------------------------- 
        // Tile Dimensions
        //----------------------------------------------------------------------

        logic [15:0] rows;
        logic [15:0] cols;
        logic [15:0] k_size;

        //---------------------------------------------------------------------- 
        // Tile Strides
        //----------------------------------------------------------------------

        logic [15:0] stride_a;
        logic [15:0] stride_b;

        //---------------------------------------------------------------------- 
        // Scratchpad Banks
        //
        // bank_a      -> compressed A values
        // bank_b      -> B values
        // metadata_bank -> sparse metadata
        // bank_c      -> destination/result scratchpad bank
        //----------------------------------------------------------------------

        logic [3:0] bank_a;
        logic [3:0] bank_b;
        logic [3:0] bank_c;
        logic [3:0] metadata_bank;

        //---------------------------------------------------------------------- 
        // Transfer Sizes
        //----------------------------------------------------------------------

        // Number of bytes occupied by compressed A values.
        logic [31:0] transfer_bytes_a;

        // Number of bytes occupied by B values.
        logic [31:0] transfer_bytes_b;

        // Number of bytes occupied by metadata.
        logic [31:0] metadata_transfer_bytes;

    } sparse_tile_request_t;

endpackage