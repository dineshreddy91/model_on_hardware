#!/usr/bin/env bash
set -euo pipefail
openjev_repo="$(cd "$(dirname "$0")/../../.." && pwd)"
openjev_sdk="${AWS_FPGA_REPO:?Set AWS_FPGA_REPO to the F2 HDK checkout}"
openjev_output="${1:?Pass a simulation output directory}"
mkdir -p "$openjev_output"
openjev_output="$(cd "$openjev_output" && pwd)"
python3 "$openjev_repo/full_model/program/core_fixture.py" generate "$openjev_output/fixture"
openjev_paths=("$openjev_repo/full_model/rtl/openjev_fp32_pkg.sv")
for openjev_path in "$openjev_repo"/full_model/rtl/*.sv; do
  [[ "$openjev_path" == */openjev_fp32_pkg.sv ]] || openjev_paths+=("$openjev_path")
done
cd "$openjev_output"
xvlog --sv "$openjev_sdk/hdk/common/lib/interfaces.sv" \
  "$openjev_repo/aws_f2/hbm_matvec/design/cl_dram_dma_pkg.sv" \
  "${openjev_paths[@]}" "$openjev_repo/aws_f2/full_model/design/cl_dram_dma_axi_mstr.sv" \
  "$openjev_repo/aws_f2/full_model/sim/tb_openjev_model_shell.sv" > compile.txt 2>&1
xelab --timescale 1ns/1ps tb_openjev_model_shell -s openjev_model_shell > elaborate.txt 2>&1
xsim openjev_model_shell -testplusarg "directory=$openjev_output/fixture" -runall > simulation.txt 2>&1
cat simulation.txt
python3 "$openjev_repo/full_model/program/core_fixture.py" check "$openjev_output/fixture"
