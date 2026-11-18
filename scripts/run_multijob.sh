#!/bin/sh
# Multi-job descriptor-addressing test.   sh scripts/run_multijob.sh [N=32] [SEED=1] [extra vvp args, e.g. +IDENT]
# Env: SRC=<rtl dir> (e.g. original RTL, to show the negative control FAILS)
set -e
N=${1:-32}; SEED=${2:-1}
if [ $# -ge 2 ]; then shift 2; else shift $#; fi
TBM=multijob_tb
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$ROOT/src}"; TBD="$ROOT/verification/tb"; MEM="$ROOT/mem files"
TBF="$TBD/multijob_tb.sv"; [ -f "$TBF" ] || { echo "missing $TBF"; exit 1; }
W="$ROOT/build/tb_$TBM"; rm -rf "$W"; mkdir -p "$W/mem files" "$ROOT/results"
cp "$MEM"/*.mem "$W/mem files"/ 2>/dev/null || true      # real .mem files are never modified
python3 "$ROOT/scripts/gen_multijob.py" --jobs "$N" --seed "$SEED" --out "$W/mem files" --gold "$W/gold_multi.mem" | grep -E "GENMJ|FAIL" || true
cp "$W/mem files"/*.mem "$W"/
PKGS=$(find "$SRC" -name '*_pkg.sv' | sort)
REST=$(find "$SRC" \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' | sort)
LOG="$ROOT/results/$TBM.log"
( cd "$W" && iverilog -g2012 -D__ICARUS__ $DEFS -I "$SRC" -I "$TBD" -I "$ROOT/verification" \
    -s "$TBM" -o sim.vvp $PKGS $REST "$TBF" && vvp sim.vvp +N="$N" "$@" ) > "$LOG" 2>&1 || true
OOB=$(grep -c "MEM_OOB" "$LOG" || true)
echo "log: $LOG  ($(wc -l < "$LOG") lines)   MEM_OOB beats: $OOB"
grep -E "MULTIJOB|FAIL|ERROR|TIMEOUT|error:|job " "$LOG" | tail -25
[ "$OOB" = "0" ] || echo "FAIL: out-of-range memory reads (see MEM_OOB in log)"