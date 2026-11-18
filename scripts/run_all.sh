#!/bin/sh
# Regression for the NeuroCore accelerator (unit + integration testbenches).
#   sh scripts/run_all.sh          (needs iverilog >= 12 and python3)
# Logs: results/<tb>.log     Summary: results/run_all.txt
# Out-of-date unit testbenches live in verification/stale/ and are not run here.
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT" || exit 1
mkdir -p results; OUT=results/run_all.txt; : > "$OUT"; ok=0; bad=0; t0=$(date +%s)
check() {   # check <label> <PASS|FAIL>
  if [ "$2" = PASS ]; then ok=$((ok+1)); r="PASS"; else bad=$((bad+1)); r="FAIL"; fi
  printf '%-44s %s\n' "$1" "$r" | tee -a "$OUT"
}
tb() {      # tb <module> <regex that only a passing run prints>
  sh scripts/run_tb.sh "$1" >/dev/null 2>&1
  if grep -qE "$2" "results/$1.log" && ! grep -qE "\[FAIL\]|^FAIL|TIMEOUT|error:" "results/$1.log"
  then check "$1" PASS; else check "$1" FAIL; fi
}

# unit
tb mac_unit_tb                          "OVERALL RESULT : PASS"
tb metadata_decoder_tb                  "Metadata Decoder Test PASSED"
tb scratchpad_tb                        "All Executed Tests PASSED"
tb scratchpad_controller_tb             "SCRATCHPAD CONTROLLER TEST PASSED"
tb scratchpad_sparse_tb                 "SCRATCHPAD SPARSE TEST COMPLETE"
tb scratchpad_controller_integration_tb "OVERALL RESULT : PASS"
tb tile_walker_tb                       "OVERALL RESULT : PASS"
tb compute_controller_tb                "OVERALL RESULT : PASS"
tb compute_controller_pipelined_tb      "COMPUTE CONTROLLER \(50 seeds.*PASS"
tb sparse_compute_controller_tb         "SPARSE COMPUTE CONTROLLER TEST PASSED"
tb sparse_datapath_wrapper_tb           "SPARSE DATAPATH WRAPPER TEST COMPLETE"
# integration
tb accelerator_top_tb                   "ACCELERATOR TOP RESEARCH RUN : PASS"
for args in "32 1" "64 7 +IDENT"; do
  s=$(sh scripts/run_multijob.sh $args 2>&1)
  r=$(echo "$s" | grep -q "MULTIJOB: PASS" && echo "$s" | grep -q "MEM_OOB beats: 0" && echo PASS || echo FAIL)
  check "multijob_tb ($args)" "$r"
done

printf -- '----\npassed: %s   failed: %s   (%ss)\n' $ok $bad $(( $(date +%s) - t0 )) | tee -a "$OUT"
[ "$bad" = 0 ]
