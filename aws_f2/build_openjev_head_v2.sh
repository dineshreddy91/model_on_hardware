#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
aws_fpga_repo="${AWS_FPGA_REPO:-/mnt/fpga-build/aws-fpga}"

source /etc/profile.d/default_module.sh
source "${aws_fpga_repo}/sdk_setup.sh"
source "${aws_fpga_repo}/hdk_setup.sh"

export CL_DIR="${script_dir}/classifier_head"
cd "${CL_DIR}/build/scripts"
"${aws_fpga_repo}/hdk/common/shell_stable/build/scripts/aws_build_dcp_from_cl.py" \
  -c cl_axil_reg_access -t openjev_head_bram_v2
