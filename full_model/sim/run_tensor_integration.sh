#!/usr/bin/env bash
set -euo pipefail
openjev_root="$(cd "$(dirname "$0")/.." && pwd)"
openjev_output="${1:?Pass an output directory}"
mkdir -p "$openjev_output"
openjev_sources=(fp32_pkg fp32_alu scalar special attention gated_delta head_dispatch hbm_element tensor_address tensor_memory tensor_port quantize_row rope scaled_int32 causal_conv)
openjev_paths=()
for openjev_source in "${openjev_sources[@]}"; do
  openjev_paths+=("$openjev_root/rtl/openjev_${openjev_source}.sv")
done
python3 "$openjev_root/tools/make_fp32_vectors.py" "$openjev_output/fp32.txt"
python3 "$openjev_root/tools/check_special.py" generate "$openjev_output/special.txt"
python3 "$openjev_root/tools/check_head_dispatch.py" generate "$openjev_output"
python3 "$openjev_root/tools/check_quantize.py" generate "$openjev_output"
python3 "$openjev_root/tools/check_rope.py" generate "$openjev_output"
python3 "$openjev_root/tools/make_small_integer_vectors.py" "$openjev_output/small_integer.txt"
python3 "$openjev_root/tools/check_causal_conv.py" generate "$openjev_output"
for openjev_test in small_integer fp32_alu special hbm_element tensor_address tensor_memory tensor_port head_dispatch quantize_row rope causal_conv; do
  iverilog -g2012 -s "tb_openjev_${openjev_test}" -o "$openjev_output/${openjev_test}.vvp" \
    "${openjev_paths[@]}" "$openjev_root/sim/tb_openjev_${openjev_test}.sv" \
    2>"$openjev_output/${openjev_test}-compile.txt"
  openjev_fixture="$openjev_test"
  case "$openjev_test" in fp32_alu) openjev_fixture=fp32;; head_dispatch) openjev_fixture=heads;; quantize_row) openjev_fixture=quantize;; esac
  vvp "$openjev_output/${openjev_test}.vvp" "+vectors=$openjev_output/${openjev_fixture}.txt" \
    "+results=$openjev_output/${openjev_fixture}-results.txt" | tee "$openjev_output/${openjev_test}-simulation.txt"
done
python3 "$openjev_root/tools/check_special.py" check "$openjev_output/special-results.txt" | tee "$openjev_output/special-comparison.txt"
python3 "$openjev_root/tools/check_head_dispatch.py" check "$openjev_output" | tee "$openjev_output/heads-comparison.txt"
python3 "$openjev_root/tools/check_quantize.py" check "$openjev_output" | tee "$openjev_output/quantize-comparison.txt"
python3 "$openjev_root/tools/make_fp32_scale_vectors.py" "$openjev_output/scale.txt"
vvp "$openjev_output/fp32_alu.vvp" "+vectors=$openjev_output/scale.txt" | tee "$openjev_output/scale-simulation.txt"

python3 "$openjev_root/tools/check_rope.py" check "$openjev_output" | tee "$openjev_output/rope-comparison.txt"
python3 "$openjev_root/tools/check_causal_conv.py" check "$openjev_output" | tee "$openjev_output/causal-conv-comparison.txt"
