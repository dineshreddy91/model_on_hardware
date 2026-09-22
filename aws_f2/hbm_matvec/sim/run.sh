#!/usr/bin/env bash
set -euo pipefail
src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
repo="${AWS_FPGA_REPO:-/mnt/fpga-build/aws-fpga}"
rtl="$src/../../full_model/rtl"
if [[ ! -d "$rtl" ]]; then rtl="$src/design"; fi
mkdir -p "${1:?Usage: run.sh OUTPUT_DIR}"
cd "$1"
xvlog -sv "$repo/hdk/common/lib/interfaces.sv" "$src/design/cl_dram_dma_pkg.sv" "$rtl/openjev_int8_matvec.sv" "$rtl/openjev_hbm_weight_reader.sv" "$src/design/cl_dram_dma_axi_mstr.sv" "$src/sim/tb_hbm_shell.sv"
xelab --timescale 1ns/1ps tb_hbm_shell -s shell_sim
xsim shell_sim -runall | tee shell_result.log
grep -q '^PASS HBM shell:' shell_result.log
