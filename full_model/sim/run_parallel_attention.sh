#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?Pass output directory}"
mkdir -p "$out"
python3 "$root/tools/check_attention_delta.py" generate "$out"
for lanes in 0 4; do
  iverilog -g2012 -s tb_openjev_attention -Ptb_openjev_attention.LANES="$lanes" \
    -Ptb_openjev_attention.READ_LATENCY=64 -o "$out/attention-$lanes.vvp" \
    "$root/rtl/openjev_fp32_pkg.sv" "$root/rtl/openjev_fp32_alu.sv" \
    "$root/rtl/openjev_scalar.sv" "$root/rtl/openjev_attention.sv" \
    "$root/sim/tb_openjev_attention.sv" 2>"$out/compile-$lanes.log"
  vvp "$out/attention-$lanes.vvp" "+vectors=$out/attention.txt" \
    "+results=$out/results-$lanes.txt" > "$out/simulation-$lanes.log"
done
cmp "$out/results-0.txt" "$out/results-4.txt"
cp "$out/results-4.txt" "$out/attention-results.txt"
python3 "$root/tools/check_attention_delta.py" attention "$out"
python3 "$root/tools/check_parallel_attention.py" "$out"
