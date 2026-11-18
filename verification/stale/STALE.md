# Stale unit testbenches

These testbenches were written against earlier versions of the RTL and have not
been updated since. They **fail (or hang) identically on the original
`research_study` RTL and on this cleaned-up RTL**, so the failures are not
regressions; the expectations are out of date. Changes they predate include:

- the flat main-memory address map (descriptor addresses now drive memory),
- the optimised sparse operand loader and the "hold compute_start until busy" handshake,
- `bytes_per_element` packed into the flags word,
- the transfer engine's current port list (`sparse_transfer_engine_tb` no longer elaborates).

The same blocks are exercised end to end by the passing integration tests
(`accelerator_top_tb`, `multijob_tb`) and by the full-system tests in NeuroCore.

To run one anyway:  `TBD=verification/stale sh scripts/run_tb.sh <tb_module>`

TODO: update each to the current interfaces, or retire it.
