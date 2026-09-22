#!/usr/bin/env bash
set -euo pipefail
openjev_root="$(cd "$(dirname "$0")/.." && pwd)"
openjev_output="${1:?Pass an output directory outside the source tree}"
mkdir -p "$openjev_output"
python3 "$openjev_root/tools/make_fp32_vectors.py" "$openjev_output/fp32.txt"
python3 "$openjev_root/tools/check_scalar.py" generate "$openjev_output/scalar.txt"
python3 "$openjev_root/tools/check_vector.py" generate "$openjev_output/vector.txt"
python3 "$openjev_root/tools/check_vector.py" generate-hbm "$openjev_output/pipeline.txt"
openjev_sources=(fp32_pkg fp32_alu scalar vector command_scheduler hbm_activation_writer hbm_vector)
openjev_paths=()
for openjev_source in "${openjev_sources[@]}"; do
  openjev_paths+=("$openjev_root/rtl/openjev_${openjev_source}.sv")
done
for openjev_test in fp32 scalar vector command_scheduler hbm_pipeline; do
  iverilog -g2012 -s "tb_openjev_${openjev_test}" \
    -o "$openjev_output/${openjev_test}.vvp" "${openjev_paths[@]}" \
    "$openjev_root/sim/tb_openjev_${openjev_test}.sv" \
    2>"$openjev_output/${openjev_test}-compile.log" || {
      cat "$openjev_output/${openjev_test}-compile.log"; exit 1;
    }
  openjev_fixture="$openjev_test"
  if [[ "$openjev_test" == hbm_pipeline ]]; then openjev_fixture=pipeline; fi
  vvp "$openjev_output/${openjev_test}.vvp" \
    "+vectors=$openjev_output/$openjev_fixture.txt" \
    "+results=$openjev_output/$openjev_fixture-results.txt"
done
python3 "$openjev_root/tools/check_scalar.py" check "$openjev_output/scalar-results.txt"
python3 "$openjev_root/tools/check_vector.py" check "$openjev_output/vector.txt" "$openjev_output/vector-results.txt"
python3 "$openjev_root/tools/check_vector.py" check "$openjev_output/pipeline.txt" "$openjev_output/pipeline-results.txt"
