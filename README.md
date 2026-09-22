# Model on Hardware

FPGA work for running the quantized OpenJEV Qwen 3.5 0.8B NLI model on an AWS
EC2 F2 (`f2.6xlarge`) instance.

## Full-model status — September 22, 2026

The complete graph compiler, attention, gated-delta recurrence, remaining
operators, HBM integration and host benchmark runner are implemented. The graph
contains 1,291 instructions and 2,458 tensor descriptors. CPU work in the FPGA
benchmark is limited to input preparation, transfers/control and output handling;
the separate CPU oracle is used only for validation.

Integrated RTL simulation passes repeated synthetic graph execution. The v8
standalone synthesis meets its 4 ns constraint (+0.170 ns setup slack); the AWS
shell build has passed synthesis and is in physical implementation. This is not
yet routed timing closure or full-model hardware execution.

AWS terminated the previous F2 Spot instance. The active r6i.xlarge is the CPU
builder; a replacement F2 endpoint is needed to load the new AFI and measure
Doom/Box Runner inference. **Full-model FPGA predictions and latency are not
available yet.** See [implementation and validation status](full_model/MODEL_INTEGRATION.md)
and [benchmark runner](full_model/program/run_fpga_benchmark.py).

Model source: [AlexWortega/openjev](https://huggingface.co/AlexWortega/openjev),
checkpoint directory `qwen3.5-0.8b-nli-v2s-long`. AWS HDK-derived files retain
their original copyright headers and are accompanied by `AWS_HDK_LICENSE.txt`.

## What is implemented

- A custom AWS F2 classifier-head design with the real 3 x 1024 INT8 OpenJEV
  classifier weights stored in inferred block RAM.
- An AXI-Lite control path that loads a 1024-element INT8 activation, runs the
  three dot products, and returns signed 32-bit accumulators.
- A host-side hardware test that waits for the accelerator's `done` status and
  verifies the expected accumulators `26198`, `35544`, and `-38063`.
- A reusable 32-lane signed INT8 dot-product tile and Vivado simulations.
- Tools that pack all 732 checkpoint tensors into 32 striped HBM images.
- A complete tensor-graph program, plus the original 42-stage architectural
  inventory, and activation calibration for all 237 linear modules.
- A C++ HBM loader with complete readback verification in the benchmark runner.

The v2 AWS F2 design completed place and route with its worst reported timing
path meeting timing at **+0.080 ns slack**. AWS created AFI
`afi-058c641e7c54ae442` / AGFI `agfi-0d2a6c428a2d5bdfb`; the image loaded into
F2 slot 0 with status `ok`. Five consecutive hardware runs reproduced all three
reference accumulators exactly.

This repository does not claim that the entire 0.8B model currently executes in
FPGA fabric. The previously tested HBM AFI, `afi-0c11d6d84c69c667d` /
`agfi-0c98e7286f4bae29b`, executes real-weight INT8 matrix operations from physical
HBM. Three runs each matched all 6,144 QKV and 768 vision outputs exactly.
The complete-model operators are now implemented and simulation-tested, but
have not been deployed as a full-model AFI. See
[the matrix engine validation record](full_model/MATVEC.md).

## Repository layout

```text
aws_f2/classifier_head/
  design/       F2 custom logic and real classifier weight memories
  software/     F2 host-side hardware tests
  build/        constraints and DCP build scripts
  verif/        AWS example verification environment
aws_f2/build_openjev_head_v2.sh
full_model/
  rtl/          reusable INT8 compute tile
  sim/          synthetic and real-weight simulations
  host/         32-bank HBM loader
  tools/        packing, calibration, fixture, and plan generators
  *.json        verified calibration, execution plan, and HBM manifest
```

Generated Vivado checkpoints, logs, simulation caches, compiled binaries, the
source checkpoint, and the 923 MB of generated HBM bank images are intentionally
excluded. Use `full_model/tools/build_openjev_hbm.py` to reproduce the bank
images from a locally obtained checkpoint.

## Build the AWS F2 classifier design

Install and configure the AWS FPGA HDK on an F2 development instance. The build
was verified with Vivado 2025.1 and the `f2` branch of `aws/aws-fpga`.

```bash
git clone --branch f2 https://github.com/aws/aws-fpga.git /mnt/fpga-build/aws-fpga
export AWS_FPGA_REPO=/mnt/fpga-build/aws-fpga
./aws_f2/build_openjev_head_v2.sh
```

The AWS build flow writes the DCP and AFI input tarball below
`aws_f2/classifier_head/build/`. AFI registration additionally requires an S3
bucket and AWS permissions for `ec2:CreateFpgaImage`.

## Run the host hardware test

After loading the generated AFI into FPGA slot 0:

```bash
source "$AWS_FPGA_REPO/sdk_setup.sh"
make -C aws_f2/classifier_head/software/runtime test_openjev_head
sudo aws_f2/classifier_head/software/runtime/test_openjev_head
```

The test succeeds only when all three FPGA accumulators match the software
fixture exactly.

## Run the full-model component tests

```bash
python -m pytest -q full_model/tools/test_openjev_hbm.py

cd full_model/sim
xvlog -sv ../rtl/openjev_int8_dot_tile.sv tb_openjev_int8_dot_tile.sv
xelab tb_openjev_int8_dot_tile -s openjev_dot_sim
xsim openjev_dot_sim -runall

xvlog -sv ../rtl/openjev_int8_dot_tile.sv tb_openjev_real_head_tile.sv
xelab tb_openjev_real_head_tile -s openjev_real_head_sim
xsim openjev_real_head_sim -runall
```

## Safety boundary

OpenJEV is a three-label natural-language-inference classifier. It does not
measure distance, closing velocity, LiDAR geometry, or machine stopping time.
A safety product must keep deterministic sensor validation, distance and
stopping calculations, watchdogs, degraded-mode behavior, and the physical stop
path outside this model.

The new [HBM shell integration](aws_f2/hbm_matvec/README.md) connects the matrix
engine to real HBM through the F2 small shell's AXI crossbar. Routed timing
passes, the AFI is loaded, and physical HBM weight readback and all six matrix
tests pass. The host uses BAR4 programmed I/O. See the integration's validation
records for counts, timings, and the scope of these tests.
