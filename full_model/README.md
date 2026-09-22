> Current status: [full-model dispatcher, shell and benchmark integration](MODEL_INTEGRATION.md). New RTL passes integration simulation; full-model hardware execution and latency remain unmeasured.

> Further implementation: [tensor/HBM integration, multihead scheduling and timing work](TENSOR_INTEGRATION.md).

> Update: attention, gated-delta and the complete tensor-graph lowering are implemented and simulation-tested. The last F2 ran the matrix-only AFI before AWS terminated it as a Spot interruption. The separate physical builder remains running; see [current recovery and build status](MODEL_INTEGRATION.md).

# OpenJEV full-model accelerator for AWS F2

This project is the end-to-end FPGA implementation workspace for
`AlexWortega/openjev/qwen3.5-0.8b-nli-v2s-long` on one `f2.6xlarge` VU47P FPGA.

## Current verified state

- The entire quantized checkpoint is represented: 732 of 732 tensors.
- Matrix and convolution weights use signed INT8 with per-output-channel FP16 scales.
- Norms, recurrent state parameters, and other sensitive vectors remain FP16.
- The packed model occupies 923,140,096 bytes including alignment and striping.
- Each of 32 HBM pseudochannels has a 28,848,128-byte image.
- The complete graph has 1,291 instructions and 2,458 tensor descriptors; the
  older 42-stage file is an architectural inventory.
- The reusable 32-wide signed INT8 dot-product tile passes synthetic Vivado simulation.
- The same tile exactly reproduces the real classifier accumulators:
  `26198, 35544, -38063`.
- All 237 PyTorch linear modules have image-derived activation ranges and INT8 scales.
- The C++ host loader has written and read back all 923,140,096 checkpoint
  bytes across 32 physical HBM banks using PCI BAR4. This memory test used the
  existing matrix AFI; it is not full-model inference.

This does not yet mean that the complete model is executing on the FPGA. The HBM
bank reader and streaming matrix-vector engine now pass integrated RTL simulation
and standalone synthesis; see [MATVEC.md](MATVEC.md). The physical HBM shell
integration has passed routed timing and physical hardware validation for two
real-weight matrices, each on three runs; see
[the HBM integration](../aws_f2/hbm_matvec/README.md). The parallel matrix array remains unfinished. Attention and gated-delta RTL,
the complete tensor-graph compiler, loader and graph sequencer now pass simulation
and compiler tests; see [attention, recurrence and graph results](ATTENTION_DELTA_GRAPH.md).
Their HBM adapters and shell wrapper now pass integration simulation; physical
full-model deployment remains unfinished. A vector/nonlinear unit and descriptor scheduler now pass integrated
HBM simulation; see [vector operators and scheduling](VECTOR_SCHEDULER.md).

Full-image inference work now includes standalone activation-writeback RTL and
an INT32/FP16-to-FP32 scaling primitive, with passing simulations. These are not
integrated into the registered AFI. See [implementation status and acceptance
gates](FULL_FPGA_IMPLEMENTATION.md). Replacement F2 `i-08d637784fd83abd2`
has reproduced the existing matrix hardware tests. The new vector path has not
been loaded onto it.

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
- `host/openjev_hbm_loader.cpp`: RAII-based DMA/PCI loader with complete readback verification.
- `host/model_runtime.py`: FPGA graph configuration, execution and latency reporting.
- `program/run_fpga_benchmark.py`: Doom/Box Runner requests with CPU input/output handling.
- `program/reference_graph.py`: separate offline CPU numerical oracle; never used as an inference fallback.
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

## Restore lost generated weights

`tools/restore_quantized_checkpoint.py ORIGINAL_SAFETENSORS hbm_manifest.json OUTPUT`
reconstructs the per-channel INT8 checkpoint and refuses to write it unless every
tensor matches the saved shape, dtype, and SHA256. Recovery from Hugging Face
revision `f004f37e52695d6ddfb914a64dbf93942839ba1e` reproduced all 732 tensors,
and rebuilding the packed images reproduced all 32 saved bank hashes.
