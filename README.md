# NeuroCore Accelerator

[![regression](https://github.com/SandyGowda-op/neurocore-accel/actions/workflows/regression.yml/badge.svg)](https://github.com/SandyGowda-op/neurocore-accel/actions/workflows/regression.yml)

A descriptor-driven matrix accelerator in SystemVerilog with two compute
paths behind one interface: **dense 8×8** and **2:4 structured-sparse 8×8**.
A descriptor (source/destination addresses, dimensions, strides, flags) is
written into descriptor memory; one `run` pulse fetches it, moves the operands
with the accelerator's own DMA engine, computes, and signals `all_done`.
Results are read one element at a time through an indexed read port.

This is the accelerator on its own. In
[NeuroCore](https://github.com/SandyGowda-op/neurocore) it is driven by a
RISC-V CPU through custom instructions.

## Block diagram

```
 cpu_we/idx/word ─► descriptor memory (128 × 8 × 32-bit)
 run, job_index ──► top sequencer ─► descriptor fetch unit ─► descriptor controller
                                                               │ validates rows/cols/k != 0
                                                               │ flags[0] → dense / sparse
                                                         scheduler engine
                                  ┌────────────────────────────┴────────────────────────────┐
                        dense subsystem                                          sparse subsystem
          dense scheduler → tile walker → tile generator                 sparse tile generator
          transfer engine (burst DMA + FIFO) → scratchpad A/B         transfer engine → scratchpad A/B/meta
          pipelined compute controller (1 MAC/cycle)                  operand loader → 8×8 sparse compute
                                  └──────────────► result_read_index / result_read_data ◄────┘
```

## Descriptor format (8 × 32-bit words)

| Word | Field |
|---|---|
| 0 | source A address |
| 1 | source B address |
| 2 | metadata address (sparse) |
| 3 | destination address (currently unused) |
| 4 | rows[31:16], cols[15:0] |
| 5 | k[31:16], strideA[15:0] |
| 6 | strideB[31:16], strideC[15:0] |
| 7 | bytes_per_element[15:8], flags[7:0] (bit 0 = sparse) |

2:4 metadata: one 3-bit code per group of four A values, naming which two
positions are kept (6 codes for the 6 possible pairs).

## Results

`sh scripts/run_all.sh`, clean checkout; passes on Icarus Verilog 12.0 and 14.0 (devel). All 14 pass in
about 5 s:

| Testbench | What it checks |
|---|---|
| `mac_unit_tb` | signed MAC, clear, skip |
| `metadata_decoder_tb` | 2:4 metadata decoding |
| `scratchpad_tb`, `scratchpad_controller_tb`, `scratchpad_sparse_tb`, `scratchpad_controller_integration_tb` | banks, 64→32-bit DMA writes, sparse read ports, read-after-write timing |
| `tile_walker_tb` | tile traversal |
| `compute_controller_tb` | dense 8×8 GEMM with signed operands |
| `compute_controller_pipelined_tb` | pipelined controller vs original, 50 random seeds |
| `sparse_compute_controller_tb`, `sparse_datapath_wrapper_tb` | sparse compute path |
| `accelerator_top_tb` | sparse and dense jobs end to end; the **same** A×B through both paths must agree with each other and a golden model (shipped data and a random case) |
| `multijob_tb` (×2) | 32 and 64 different descriptors, each addressing a different memory window |

Measured one-tile performance (from `accelerator_top_tb`):

| | Dense | Sparse 2:4 |
|---|---|---|
| MACs | 512 | 256 |
| Compute phase | 580 cycles | 322 cycles |
| Whole job | 826 cycles | 610 cycles |
| Bytes moved | 512 B | 448 B (incl. 64 B metadata) |

`verification/stale/` holds older unit testbenches written against earlier
versions of the RTL; they fail identically before and after recent changes,
so they are kept out of the regression (see `STALE.md`).

## Known limits

- One 8×8 tile per descriptor; no K-tile accumulation; results are not
  written back to memory.
- `main_memory_model.sv` is a behavioural simulation model, one private copy
  per subsystem, read-only. It is black-boxed in synthesis.
- The sparse path trusts the descriptor and metadata (no 2:4 validation).
- The dense MAC counter is cumulative across jobs.

## Run it

```sh
sh scripts/run_all.sh                       # needs iverilog >= 12, python3
sh scripts/run_tb.sh accelerator_top_tb     # one testbench
sh scripts/synth_nangate.sh accelerator_top 10   # Yosys+slang, Nangate45 .lib, OpenSTA
```

## Layout

```
src/                  accelerator RTL (accelerator_top.sv is the top)
verification/tb/      testbenches in the regression
verification/stale/   out-of-date unit testbenches
scripts/              run_all.sh, run_tb.sh, multijob generator, synthesis
tools/                sparse memory-image generator
mem files/            operand images for the shipped tests
legacy/rtl/           retired modules
```

## License

MIT
