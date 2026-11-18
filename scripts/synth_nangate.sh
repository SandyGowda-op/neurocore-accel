#!/bin/sh
# Post-synthesis area + timing for one top module, Nangate45 typical corner.
# usage: sh scripts/synth_nangate.sh [top] [clock_period_ns]
#   LIB=<path to .lib>   (default: ~/eda_libs/NangateOpenCellLibrary_typical.lib)
#   SRAM_BB=0            synthesise descriptor memory as flip-flops (default 1: treat it as an
#                        SRAM macro / black box, as a real chip would; as flip-flops its huge
#                        read mux dominates area and gives meaningless high-fanout timing)
# Needs: yosys with the slang plugin (OSS CAD Suite), OpenSTA (`sta`) for timing.
# Full output: results/synth/<top>/run.log (yosys.log, area.rpt, sta.log alongside)
# Numbers are post-synthesis, pre-layout (no wire load): Fmax is optimistic.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOP=${1:-accelerator_top}; PERIOD=${2:-10}
LIB=${LIB:-$HOME/eda_libs/NangateOpenCellLibrary_typical.lib}
SRAM_BB=${SRAM_BB:-1}
OUT="$ROOT/results/synth/$TOP"; mkdir -p "$OUT"
[ -f "$LIB" ] || { echo "liberty file not found: $LIB (set LIB=...)"; exit 1; }
exec 3>&1 > "$OUT/run.log" 2>&1     # everything below goes to run.log; fd 3 = terminal

# black-box stub for the behavioural DMA memory model (it is a simulation model, not RTL)
cat > "$OUT/bb.sv" <<'EOF'
(* blackbox *)
module main_memory_model #(
  parameter integer DATA_WIDTH = 64, parameter integer MEMORY_SIZE = 65536,
  parameter integer MEMORY_LATENCY = 3, parameter string MEMORY_INIT_FILE = "",
  parameter bit VERBOSE = 1'b0, parameter logic [31:0] MEM_BASE = 32'h1000_0000
)( input logic clk, input logic rst,
   input logic mem_req_valid, output logic mem_req_ready,
   input logic [31:0] mem_req_addr, input logic [31:0] mem_req_bytes,
   input logic mem_req_write,
   output logic mem_rvalid, output logic [63:0] mem_rdata, output logic mem_rlast );
endmodule
EOF

EXCL="! -name main_memory_model.sv"
if [ "$SRAM_BB" = 1 ] && [ "$TOP" != descriptor_memory ]; then
cat >> "$OUT/bb.sv" <<'EOF'
(* blackbox *)
module descriptor_memory import descriptor_pkg::*; #(
  parameter string INIT_FILE = "", parameter bit USE_INIT_FILE = 1'b0
)( input logic clk,
   input logic cpu_re, input logic cpu_we,
   input logic [DESC_INDEX_WIDTH-1:0] cpu_desc_idx,
   input logic [WORD_COUNTER_WIDTH-1:0] cpu_word_offset,
   input descriptor_mem_word_t cpu_wdata, output descriptor_mem_word_t cpu_rdata,
   input logic dfu_re,
   input logic [DESC_INDEX_WIDTH-1:0] dfu_desc_idx,
   input logic [WORD_COUNTER_WIDTH-1:0] dfu_word_offset,
   output descriptor_mem_word_t dfu_rdata );
endmodule
EOF
EXCL="$EXCL ! -name descriptor_memory.sv"
fi

PKGS=$(find "$ROOT/src" -name '*_pkg.sv' | sort)
REST=$(find "$ROOT/src" \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' $EXCL | sort)

cat > "$OUT/synth.ys" <<EOF
plugin -i slang
read_slang --top $TOP -D SYNTHESIS $SYN_DEFS --keep-hierarchy $(echo $PKGS $REST) $OUT/bb.sv
hierarchy -check -top $TOP
synth -top $TOP
delete t:\$print
dfflibmap -liberty $LIB
abc -liberty $LIB -D $(( PERIOD * 1000 ))
opt_clean -purge
tee -o $OUT/area.rpt stat -liberty $LIB -top $TOP
write_verilog -noattr $OUT/netlist.v
# --- flat, plain-structural netlist for OpenSTA ---
flatten
splitnets -ports
setundef -zero
hilomap -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z
insbuf -buf BUF_X1 A Z
opt_clean -purge
setparam -unset DATA_WIDTH -unset MEMORY_SIZE -unset MEMORY_LATENCY -unset MEMORY_INIT_FILE -unset VERBOSE -unset MEM_BASE t:main_memory_model*
setparam -unset INIT_FILE -unset USE_INIT_FILE t:descriptor_memory*
write_verilog -noattr -noexpr -nohex -nodec $OUT/netlist_flat.v
EOF
yosys -q -l "$OUT/yosys.log" -s "$OUT/synth.ys"

cat > "$OUT/sta.tcl" <<EOF
read_liberty $LIB
read_verilog $OUT/netlist_flat.v
link_design $TOP
create_clock -name clk -period $PERIOD [get_ports clk]
report_checks -path_delay max -fields {cap slew} -digits 3
report_worst_slack -digits 3
exit
EOF
if command -v sta >/dev/null 2>&1; then
  sta -no_splash -exit "$OUT/sta.tcl" > "$OUT/sta.log" 2>&1 || true
fi

# short summary to the terminal
exec 1>&3 2>&3
echo "==== $TOP  (Nangate45 typical, ${PERIOD} ns, descriptor memory as SRAM black box: $SRAM_BB) ===="
grep "Chip area for top" "$OUT/area.rpt" || true
echo "conflicting-driver warnings: $(grep -c 'conflicting drivers' "$OUT/yosys.log")"
grep -i -E "worst slack|^Error" "$OUT/sta.log" 2>/dev/null || echo "no STA result -- see $OUT/sta.log"
echo "Fmax = 1000 / ($PERIOD - worst_slack) MHz   | full logs: $OUT/"