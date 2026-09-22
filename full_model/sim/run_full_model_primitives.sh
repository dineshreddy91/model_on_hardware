#!/usr/bin/env bash
set -euo pipefail
openjev_sim_root="$(cd "$(dirname "$0")/.." && pwd)"
openjev_sim_output="${1:?Pass an output directory outside the source tree}"
mkdir -p "$openjev_sim_output"
python3 "$openjev_sim_root/tools/make_scaled_int32_vectors.py" "$openjev_sim_output/scaled-int32.txt"
for openjev_unit in hbm_activation_writer scaled_int32; do
  iverilog -g2012 -s "tb_openjev_${openjev_unit}" \
    -o "$openjev_sim_output/${openjev_unit}.vvp" \
    "$openjev_sim_root/rtl/openjev_${openjev_unit}.sv" \
    "$openjev_sim_root/sim/tb_openjev_${openjev_unit}.sv"
  vvp "$openjev_sim_output/${openjev_unit}.vvp" \
    "+vectors=$openjev_sim_output/scaled-int32.txt"
done
