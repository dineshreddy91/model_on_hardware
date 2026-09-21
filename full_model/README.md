# OpenJEV full-model accelerator for AWS F2

This project is the end-to-end FPGA implementation workspace for
`AlexWortega/openjev/qwen3.5-0.8b-nli-v2s-long` on one `f2.6xlarge` VU47P FPGA.

## Current verified state

- The entire quantized checkpoint is represented: 732 of 732 tensors.
- Matrix and convolution weights use signed INT8 with per-output-channel FP16 scales.
- Norms, recurrent state parameters, and other sensitive vectors remain FP16.
- The packed model occupies 923,140,096 bytes including alignment and striping.
- Each of 32 HBM pseudochannels has a 28,848,128-byte image.
- All model tensors are assigned to a 42-stage execution plan.
- The reusable 32-wide signed INT8 dot-product tile passes synthetic Vivado simulation.
- The same tile exactly reproduces the real classifier accumulators:
  `26198, 35544, -38063`.
- All 237 PyTorch linear modules have image-derived activation ranges and INT8 scales.
- The C++ host loader validates the complete HBM image and its physical F2 addresses.

This does not yet mean that the complete model is executing on the FPGA. The HBM
reader, tiled matrix array, vector/nonlinear unit, gated-delta state engine,
attention engine, and microcoded scheduler remain to be integrated into the AWS
shell design.

## Memory layout

Logical tensor data is split into 256-byte chunks. Chunk `j` is stored at:

```text
bank         = j % 32
bank address = tensor.base_address + (j / 32) * 256
```

Every tensor begins at the same 4 KiB-aligned address in all banks. The host DMA
window starts at `0x1000000000`; HBM pseudochannels are 512 MiB apart.

## Project contents

- `hbm/`: persistent 32-bank model images and the placement manifest.
- `execution_plan.json`: ordered vision, language, norm, and classifier stages.
- `activation_calibration.json`: reference ranges and input scales for 237 linear layers.
- `rtl/openjev_int8_dot_tile.sv`: parameterized matrix dot-product engine.
- `sim/`: synthetic and real-checkpoint RTL simulations.
- `host/openjev_hbm_loader.cpp`: RAII-based XDMA loader and optional readback verifier.
- `tools/`: checkpoint packing, calibration, fixture, and execution-plan generators.

## Verification

```bash
cd full_model

python -m pytest -q tools/test_openjev_hbm.py

cd sim
/opt/Xilinx/2025.1/Vivado/bin/xvlog -sv ../rtl/openjev_int8_dot_tile.sv tb_openjev_int8_dot_tile.sv
/opt/Xilinx/2025.1/Vivado/bin/xelab tb_openjev_int8_dot_tile -s openjev_dot_sim
/opt/Xilinx/2025.1/Vivado/bin/xsim openjev_dot_sim -runall

/opt/Xilinx/2025.1/Vivado/bin/xvlog -sv ../rtl/openjev_int8_dot_tile.sv tb_openjev_real_head_tile.sv
/opt/Xilinx/2025.1/Vivado/bin/xelab tb_openjev_real_head_tile -s openjev_real_head_sim
/opt/Xilinx/2025.1/Vivado/bin/xsim openjev_real_head_sim -runall
```

Loading or verifying HBM requires the corresponding custom AFI:

```bash
host/openjev_hbm_loader hbm --load
host/openjev_hbm_loader hbm --verify
```

## Safety boundary

OpenJEV is a three-label natural-language-inference classifier. It does not directly
estimate distance, closing velocity, lidar geometry, or machine stopping distance.
A production safety controller must keep deterministic sensor validation, distance
calculation, watchdogs, degraded-mode handling, and stop outputs outside the VLM.
