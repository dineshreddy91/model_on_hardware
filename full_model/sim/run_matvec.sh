#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir="$(cd -- "${1:?Usage: run_matvec.sh FIXTURE_DIRECTORY}" && pwd)"
# Run in a generated fixture directory to keep build products out of source.
cd "$fixture_dir"
xvlog -sv -i "$fixture_dir" "$source_dir/../rtl/openjev_int8_matvec.sv" "$source_dir/../rtl/openjev_hbm_weight_reader.sv" "$source_dir/tb_openjev_int8_matvec.sv"
xelab tb_openjev_int8_matvec -s matvec_sim
xsim matvec_sim -runall | tee matvec_result.log
grep -q '^PASS matvec:' matvec_result.log
xvlog -sv "$source_dir/../rtl/openjev_hbm_weight_reader.sv" "$source_dir/tb_openjev_hbm_weight_reader.sv"
xelab tb_openjev_hbm_weight_reader -s reader_sim
xsim reader_sim -runall | tee reader_result.log
grep -q '^PASS HBM reader:' reader_result.log
