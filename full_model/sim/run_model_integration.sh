#!/usr/bin/env bash
set -euo pipefail
openjev_root="$(cd "$(dirname "$0")/.." && pwd)"
openjev_output="${1:?Pass an output directory}"
mkdir -p "$openjev_output"
openjev_output="$(cd "$openjev_output" && pwd)"
openjev_paths=("$openjev_root/rtl/openjev_fp32_pkg.sv")
for openjev_path in "$openjev_root"/rtl/*.sv; do
  [[ "$openjev_path" == */openjev_fp32_pkg.sv ]] || openjev_paths+=("$openjev_path")
done
python3 "$openjev_root/tools/make_half_vectors.py" "$openjev_output/half.txt"
python3 "$openjev_root/tools/make_scaled_int32_vectors.py" "$openjev_output/scaled_int32.txt"
python3 "$openjev_root/tools/check_row_ops.py" generate "$openjev_output"
python3 "$openjev_root/tools/check_table_ops.py" generate "$openjev_output"
python3 "$openjev_root/program/core_fixture.py" generate "$openjev_output/core"
for openjev_test in half scaled_int32 row_ops table_ops matrix_rows model_core; do
  iverilog -g2012 -s "tb_openjev_${openjev_test}" -o "$openjev_output/${openjev_test}.vvp" \
    "${openjev_paths[@]}" "$openjev_root/sim/tb_openjev_${openjev_test}.sv" \
    2>"$openjev_output/${openjev_test}-compile.txt"
  vvp "$openjev_output/${openjev_test}.vvp" "+vectors=$openjev_output/${openjev_test}.txt" \
    "+results=$openjev_output/${openjev_test}-results.txt" "+directory=$openjev_output/core" \
    | tee "$openjev_output/${openjev_test}-simulation.txt"
done
python3 "$openjev_root/tools/check_row_ops.py" check "$openjev_output" | tee "$openjev_output/row-comparison.txt"
python3 "$openjev_root/tools/check_table_ops.py" check "$openjev_output" | tee "$openjev_output/table-comparison.txt"
python3 "$openjev_root/program/core_fixture.py" check "$openjev_output/core" | tee "$openjev_output/core-comparison.txt"
PYTHONPATH="$openjev_root/..:$openjev_root/program:${PYTHONPATH:-}" python3 -m pytest "$openjev_root/program/tests" -q
