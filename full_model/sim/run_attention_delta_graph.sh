#!/usr/bin/env bash
set -euo pipefail
openjev_root="$(cd "$(dirname "$0")/.." && pwd)"
openjev_output="${1:?Pass an output directory}"
mkdir -p "$openjev_output"
python3 "$openjev_root/tools/check_attention_delta.py" generate "$openjev_output"
for openjev_unit in attention gated_delta; do
  iverilog -g2012 -s "tb_openjev_${openjev_unit}" -o "$openjev_output/${openjev_unit}.vvp" \
    "$openjev_root/rtl/openjev_fp32_pkg.sv" "$openjev_root/rtl/openjev_fp32_alu.sv" "$openjev_root/rtl/openjev_scalar.sv" \
    "$openjev_root/rtl/openjev_${openjev_unit}.sv" "$openjev_root/sim/tb_openjev_${openjev_unit}.sv" \
    2>"$openjev_output/${openjev_unit}-compile.log"
  openjev_fixture="$openjev_unit"
  if [ "$openjev_unit" = gated_delta ]; then openjev_fixture=delta; fi
  vvp "$openjev_output/${openjev_unit}.vvp" "+vectors=$openjev_output/${openjev_fixture}.txt" \
    "+results=$openjev_output/${openjev_fixture}-results.txt" | tee "$openjev_output/${openjev_unit}-simulation.log"
  python3 "$openjev_root/tools/check_attention_delta.py" "$openjev_fixture" "$openjev_output" \
    | tee "$openjev_output/${openjev_fixture}-comparison.log"
done
iverilog -g2012 -s tb_openjev_graph_sequencer -o "$openjev_output/graph.vvp" \
  "$openjev_root/rtl/openjev_graph_sequencer.sv" "$openjev_root/sim/tb_openjev_graph_sequencer.sv"
vvp "$openjev_output/graph.vvp" | tee "$openjev_output/graph-simulation.log"
iverilog -g2012 -s tb_openjev_graph_chain -o "$openjev_output/chain.vvp" \
  "$openjev_root/rtl/openjev_fp32_pkg.sv" "$openjev_root/rtl/openjev_fp32_alu.sv" "$openjev_root/rtl/openjev_scalar.sv" \
  "$openjev_root/rtl/openjev_attention.sv" "$openjev_root/rtl/openjev_gated_delta.sv" \
  "$openjev_root/rtl/openjev_graph_sequencer.sv" "$openjev_root/sim/tb_openjev_graph_chain.sv" \
  2>"$openjev_output/chain-compile.log"
vvp "$openjev_output/chain.vvp" "+results=$openjev_output/chain-results.txt" | tee "$openjev_output/chain-simulation.log"
python3 "$openjev_root/tools/check_graph_chain.py" "$openjev_output/chain-results.txt" | tee "$openjev_output/chain-comparison.log"
iverilog -g2012 -s tb_openjev_operator_watchdog -o "$openjev_output/watchdog.vvp" \
  "$openjev_root/rtl/openjev_fp32_pkg.sv" "$openjev_root/rtl/openjev_fp32_alu.sv" "$openjev_root/rtl/openjev_scalar.sv" \
  "$openjev_root/rtl/openjev_attention.sv" "$openjev_root/rtl/openjev_gated_delta.sv" \
  "$openjev_root/sim/tb_openjev_operator_watchdog.sv" 2>"$openjev_output/watchdog-compile.log"
vvp "$openjev_output/watchdog.vvp" | tee "$openjev_output/watchdog-simulation.log"
