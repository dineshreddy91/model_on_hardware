#!/usr/bin/env bash
set -euo pipefail
openjev_build_args=("$@")
set --
openjev_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
openjev_aws_root="${AWS_FPGA_REPO:-/mnt/fpga-build/aws-fpga}"
if [[ -f /etc/profile.d/default_module.sh ]]; then source /etc/profile.d/default_module.sh; fi
cd "$openjev_aws_root"
source sdk_setup.sh
source hdk_setup.sh
export CL_DIR="${OPENJEV_CL_DIR:-/mnt/fpga-build/openjev-full-model-build/cl_dram_hbm_dma}"
if [[ "$(basename -- "$CL_DIR")" != cl_dram_hbm_dma ]]; then
  echo "OPENJEV_CL_DIR must end in cl_dram_hbm_dma" >&2
  exit 1
fi
mkdir -p "$CL_DIR/build/scripts" "$CL_DIR/build/constraints" "$CL_DIR/design"
cp "$openjev_script_dir/hbm_matvec/design/"*.sv "$openjev_script_dir/hbm_matvec/design/"*.vh "$CL_DIR/design/"
cp "$openjev_script_dir/hbm_matvec/build/scripts/"*.tcl "$CL_DIR/build/scripts/"
cp "$openjev_script_dir/hbm_matvec/build/constraints/"*.xdc "$CL_DIR/build/constraints/"
cp "$openjev_script_dir/full_model/design/"*.sv "$CL_DIR/design/"
cp "$openjev_script_dir/full_model/build/scripts/"*.tcl "$CL_DIR/build/scripts/"
cp "$openjev_script_dir/../full_model/rtl/"*.sv "$CL_DIR/design/"
for name in build_all.tcl build_level_1_cl.tcl; do
  ln -sfn "$HDK_SHELL_DIR/build/scripts/$name" "$CL_DIR/build/scripts/$name"
done
cd "$CL_DIR/build/scripts"
"$HDK_SHELL_DIR/build/scripts/aws_build_dcp_from_cl.py" -c cl_dram_hbm_dma -t openjev_full_model_v1 "${openjev_build_args[@]}"
