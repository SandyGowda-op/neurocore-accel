//==============================================================================
// Module      : sparse_scheduler
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   Top-level controller for structured sparse matrix execution.
//
// Responsibilities :
//   - Control sparse tile traversal
//   - Coordinate compressed value transfers
//   - Coordinate metadata transfers
//   - Trigger metadata decoder
//   - Launch sparse matrix engine
//   - Advance Tile Walker
//   - Signal descriptor completion
//
// Tile traversal:
//   - walker_start is asserted only once per descriptor
//   - walker_next advances to the next tile
//   - The current tile is preserved while its transfers and computation run
//
// Current architecture:
//   - 2:4 structured sparsity
//   - Sparse metadata handled separately
//   - Existing Transfer Engine infrastructure reused
//   - Existing MAC primitive reused
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

import descriptor_pkg::*;
import tile_pkg::*;

module sparse_scheduler
(
    //==========================================================================
    // Global
    //==========================================================================

    input logic clk,
    input logic rst,

    //==========================================================================
    // Descriptor Controller
    //==========================================================================

    input  logic        start,
    input  descriptor_t descriptor,
    output logic        sparse_done,

    //==========================================================================
    // Tile Walker
    //==========================================================================

    output logic          walker_start,
    output logic          walker_next,
    input  tile_context_t  current_tile,
    input  logic           first_tile,
    input  logic           last_tile,
    input  logic           walker_done,

    //==========================================================================
    // Sparse Tile Generator
    //==========================================================================

    output logic                   generator_enable,
    input  sparse_tile_request_t    generated_request,

    //==========================================================================
    // Sparse DMA
    //==========================================================================

    output logic start_value_dma,
    output logic start_metadata_dma,

    input logic value_dma_done,
    input logic metadata_dma_done,

    //==========================================================================
    // Metadata Decoder
    //==========================================================================

    output logic decoder_enable,
    input logic  decoder_done,

    //==========================================================================
    // Sparse Matrix Engine
    //==========================================================================

    output logic compute_enable,
    input logic  compute_done
);

    //==========================================================================
    // Number of K Tiles
    //==========================================================================
    //
    // Derived internally from the descriptor.
    //
    // Example:
    //
    //   K = 128
    //   TILE_K = 8
    //
    //   num_k_tiles = 128 / 8 = 16
    //
    // Ceiling division handles non-multiple dimensions.
    //==========================================================================

    logic [15:0] num_k_tiles;

    always_comb begin

        num_k_tiles =
            (descriptor.k + TILE_K - 1) / TILE_K;

    end

    //==========================================================================
    // Sparse Scheduler FSM
    //==========================================================================

    typedef enum logic [3:0]
    {
        IDLE,

        START_WALKER,

        GENERATE_TILE,

        LAUNCH_DMA,

        WAIT_DMA,

        DECODE_METADATA,

        START_COMPUTE,

        WAIT_COMPUTE,

        NEXT_TILE,

        COMPLETE,

        ERROR

    } sparse_state_t;

    sparse_state_t state;
    sparse_state_t next_state;

    //==========================================================================
    // DMA Completion Registers
    //==========================================================================

    logic value_dma_complete;
    logic metadata_dma_complete;

    //==========================================================================
    // State Register
    //==========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            state <= IDLE;

        end

        else begin

            state <= next_state;

        end

    end

    //==========================================================================
    // DMA Completion Tracking
    //==========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            value_dma_complete    <= 1'b0;
            metadata_dma_complete <= 1'b0;

        end

        else begin

            //------------------------------------------------------------------
            // Clear completion flags when beginning a new tile.
            //
            // START_WALKER is only used for the first tile.
            // For subsequent tiles, NEXT_TILE performs the walker advance
            // and the following GENERATE_TILE begins the new tile.
            //------------------------------------------------------------------

            if (state == NEXT_TILE) begin

                value_dma_complete    <= 1'b0;
                metadata_dma_complete <= 1'b0;

            end

            else begin

                //------------------------------------------------------------------
                // Latch value DMA completion.
                //------------------------------------------------------------------

                if (value_dma_done)
                    value_dma_complete <= 1'b1;

                //------------------------------------------------------------------
                // Latch metadata DMA completion.
                //------------------------------------------------------------------

                if (metadata_dma_done)
                    metadata_dma_complete <= 1'b1;

            end

        end

    end

    //==========================================================================
    // Next-State Logic
    //==========================================================================

    always_comb begin

        next_state = state;

        case (state)

            //==================================================================
            // Wait for Sparse Descriptor
            //==================================================================

            IDLE:
            begin

                if (start)
                    next_state = START_WALKER;

            end

            //==================================================================
            // Start Tile Walker
            //
            // IMPORTANT:
            // This state occurs only once at the beginning of the descriptor.
            // It resets the walker to tile (0,0,0).
            //==================================================================

            START_WALKER:
            begin

                next_state = GENERATE_TILE;

            end

            //==================================================================
            // Generate Sparse Tile Request
            //==================================================================

            GENERATE_TILE:
            begin

                next_state = LAUNCH_DMA;

            end

            //==================================================================
            // Launch Value + Metadata DMA
            //==================================================================

            LAUNCH_DMA:
            begin

                next_state = WAIT_DMA;

            end

            //==================================================================
            // Wait for Both DMA Transfers
            //==================================================================

            WAIT_DMA:
            begin

                if (value_dma_complete &&
                    metadata_dma_complete)
                begin

                    next_state = DECODE_METADATA;

                end

            end

            //==================================================================
            // Decode Sparse Metadata
            //==================================================================

            DECODE_METADATA:
            begin

                if (decoder_done)
                    next_state = START_COMPUTE;

            end

            //==================================================================
            // Start Sparse Compute
            //==================================================================

            START_COMPUTE:
            begin

                next_state = WAIT_COMPUTE;

            end

            //==================================================================
            // Wait for Sparse Compute
            //==================================================================

            WAIT_COMPUTE:
            begin

                if (compute_done)
                    next_state = NEXT_TILE;

            end

            //==================================================================
            // Advance to Next Tile
            //==================================================================
            //
            // IMPORTANT:
            //
            // We DO NOT return to START_WALKER here.
            //
            // START_WALKER resets the walker to (0,0,0).
            //
            // Instead, NEXT_TILE causes walker_next to advance:
            //
            //   (0,0,0) -> (0,0,1)
            //   (0,0,1) -> (0,0,2)
            //   ...
            //
            // After the final tile, go to COMPLETE.
            //==================================================================

            NEXT_TILE:
            begin

                if (last_tile)
                    next_state = COMPLETE;

                else
                    next_state = GENERATE_TILE;

            end

            //==================================================================
            // Descriptor Complete
            //==================================================================

            COMPLETE:
            begin

                next_state = IDLE;

            end

            //==================================================================
            // Error Recovery
            //==================================================================

            ERROR:
            begin

                next_state = IDLE;

            end

            //==================================================================
            // Safety
            //==================================================================

            default:
            begin

                next_state = IDLE;

            end

        endcase

    end

    //==========================================================================
    // Output Logic
    //==========================================================================

    always_comb begin

        //======================================================================
        // Default Outputs
        //======================================================================

        walker_start       = 1'b0;
        walker_next        = 1'b0;

        generator_enable   = 1'b0;

        start_value_dma    = 1'b0;
        start_metadata_dma = 1'b0;

        decoder_enable     = 1'b0;

        compute_enable     = 1'b0;

        sparse_done        = 1'b0;

        //======================================================================
        // State-Dependent Outputs
        //======================================================================

        case (state)

            //==================================================================
            // Start Tile Walker
            //
            // Only asserted once.
            //==================================================================

            START_WALKER:
            begin

                walker_start = 1'b1;

            end

            //==================================================================
            // Generate Sparse Tile
            //==================================================================

            GENERATE_TILE:
            begin

                generator_enable = 1'b1;

            end

            //==================================================================
            // Launch DMA
            //==================================================================

            LAUNCH_DMA:
            begin

                start_value_dma    = 1'b1;
                start_metadata_dma = 1'b1;

            end

            //==================================================================
            // Decode Metadata
            //==================================================================

            DECODE_METADATA:
            begin

                decoder_enable = 1'b1;

            end

            //==================================================================
            // Start Sparse Compute
            //==================================================================

            START_COMPUTE:
            begin

                compute_enable = 1'b1;

            end

            //==================================================================
            // Advance Tile Walker
            //==================================================================
            //
            // This is the critical correction.
            //
            // walker_next advances the existing tile context rather than
            // resetting it.
            //==================================================================

            NEXT_TILE:
            begin

                if (!last_tile)
                    walker_next = 1'b1;

            end

            //==================================================================
            // Sparse Descriptor Complete
            //==================================================================

            COMPLETE:
            begin

                sparse_done = 1'b1;

            end

            //==================================================================
            // Other States
            //==================================================================

            default:
            begin

            end

        endcase

    end

endmodule

`default_nettype wire