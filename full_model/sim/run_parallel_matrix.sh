#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?Pass output directory}"
mkdir -p "$out"
for lanes in 0 2; do
  iverilog -g2012 -s tb_openjev_matrix_rows -Ptb_openjev_matrix_rows.LANES="$lanes" \
    -o "$out/matrix-$lanes.vvp" "$root/rtl/openjev_int8_matvec.sv" \
    "$root/rtl/openjev_hbm_weight_reader.sv" "$root/rtl/openjev_matrix_rows.sv" \
    "$root/sim/tb_openjev_matrix_rows.sv" 2> "$out/compile-$lanes.txt"
  vvp "$out/matrix-$lanes.vvp" | tee "$out/matrix-$lanes.txt"
done
iverilog -g2012 -s tb_openjev_ready_fifo -o "$out/fifo.vvp" \
  "$root/rtl/openjev_ready_fifo.sv" "$root/sim/tb_openjev_ready_fifo.sv"
vvp "$out/fifo.vvp" | tee "$out/fifo.txt"
