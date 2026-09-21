# Model on Hardware

FPGA work for running the quantized OpenJEV Qwen 3.5 0.8B NLI model on an AWS
EC2 F2 (`f2.6xlarge`) instance.

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
- A 42-stage execution plan and activation calibration for all 237 linear
  modules.
- A C++ HBM loader with optional readback verification.

The v2 AWS F2 design completed place and route with its worst reported timing
path meeting timing at **+0.080 ns slack**. AWS created AFI
`afi-058c641e7c54ae442` / AGFI `agfi-0d2a6c428a2d5bdfb`; the image loaded into
F2 slot 0 with status `ok`. Five consecutive hardware runs reproduced all three
reference accumulators exactly.

This repository does not claim that the entire 0.8B model currently executes in
FPGA fabric. The custom AFI contains the classifier-head proof of concept; the
remaining vision, sequence, attention, normalization, and HBM execution engines
still need implementation.

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
