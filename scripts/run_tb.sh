#!/bin/sh
# Generic testbench runner.  Run from the project root:
#   sh scripts/run_tb.sh <tb_module_name> [extra vvp args, e.g. +TEST=2]
# Examples:
#   sh scripts/run_tb.sh riscv_pipeline_tb
#   sh scripts/run_tb.sh accelerator_top_tb
# Optional:  SRC=<rtl dir>  to compile a different RTL folder (e.g. the original files).
# What it does: finds the file that defines the module in verification/tb/, compiles
# src/ (packages first), runs in a scratch dir build/tb_<name>/ that has its own
# "mem files/" copy (your real .mem files are never modified), saves the full output to
# results/<name>.log and prints only the PASS/FAIL summary lines.
set -e
TBM=${1:?usage: run_tb.sh <tb_module_name> [vvp args]}; shift || true
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$ROOT/src}"; TBD="${TBD:-$ROOT/verification/tb}"; MEM="$ROOT/mem files"
TBD=$(cd "$TBD" && pwd)
TBF=$(grep -l "^\s*module\s\+$TBM\b" "$TBD"/*.sv "$TBD"/*.v 2>/dev/null | head -1)
[ -n "$TBF" ] || { echo "module $TBM not found in $TBD"; exit 1; }
W="$ROOT/build/tb_$TBM"; rm -rf "$W"; mkdir -p "$W/mem files" "$W/build" "$W/tb/waveforms" "$ROOT/results"
cp "$MEM"/*.mem "$W/mem files"/ 2>/dev/null || true
cp "$MEM"/*.mem "$W"/ 2>/dev/null || true
PKGS=$(find "$SRC" -name '*_pkg.sv' | sort)
REST=$(find "$SRC" \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' | sort)
LOG="$ROOT/results/$TBM.log"
( cd "$W" && iverilog -g2012 -D__ICARUS__ $DEFS -I "$SRC" -I "$TBD" -I "$ROOT/verification/tb" -I "$ROOT/verification" \
    -s "$TBM" -o sim.vvp $PKGS $REST "$TBF" && vvp sim.vvp "$@" ) > "$LOG" 2>&1 || true
echo "log: $LOG  ($(wc -l < "$LOG") lines)"
grep -E "PASS|FAIL|ERROR|TIMEOUT|error:|====" "$LOG" | tail -25