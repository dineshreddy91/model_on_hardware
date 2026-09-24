# v13 build handoff — September 23, 2026

Build finished at 17:48 UTC in 1 hour 6 minutes. Independent routed validation
passed: setup slack +0.023 ns; hold slack +0.001 ns; zero setup/hold failing
endpoints; zero routing errors; all 173,794 routable nets fully routed.
All ten reported bus-skew constraints pass (minimum slack +2.813 ns).
DRC has zero errors, 174 warnings and one advisory. Warnings include shell DDR
IO constraints/unloaded buffers, DSP pipelining and shell pblock overlap.
Timing reports identify 35 no-clock pins in hidden shell PCIe logic, zero
unconstrained internal endpoints and no missing input/output delays. AWS AFI
creation subsequently succeeded. These timing results alone do not establish
model correctness.

## Build artifact

On builder `ubuntu@ec2-3-88-106-252.compute-1.amazonaws.com`:

```
/home/ubuntu/openjev-full-shell-v13/cl_dram_hbm_dma/build/checkpoints/openjev_full_model_v1.Developer_CL.tar
```

SHA-256: `7b65e5a69b42764e1192f960b50679c7a48b2681ecd87284f91a8e4533e0d2b2`

Validation reports: `/home/ubuntu/openjev-v13-validation/` on builder; local
copies in `full_model/sim/validation/model-integration/v13/routed/`.

## Create the AFI

AFI creation was submitted at 2026-09-24 02:52 UTC:
`afi-00f49a1efd465abda` / `agfi-03b2976d4db937929`. It is available and loaded on the current F2.
Do not submit a duplicate request. The following commands document the submission. Copy the artifact through your workstation to an
AWS-authenticated machine. The builder currently has no AWS credentials.
From the directory containing the tar, use the existing FPGA bucket/profile:

```bash
aws s3 cp openjev_full_model_v1.Developer_CL.tar s3://model-on-hardware-fpga-593504801384-us-east-1/dcp/openjev-v13.Developer_CL.tar --region us-east-1
aws ec2 create-fpga-image --region us-east-1 --name openjev-full-model-v13 --input-storage-location Bucket=model-on-hardware-fpga-593504801384-us-east-1,Key=dcp/openjev-v13.Developer_CL.tar --logs-storage-location Bucket=model-on-hardware-fpga-593504801384-us-east-1,Key=afi-logs/openjev-v13
```

Record both returned IDs. Poll using the returned `afi-...`:

```bash
aws ec2 describe-fpga-images --region us-east-1 --fpga-image-ids REPLACE_WITH_AFI_ID
```

Proceed only when its State.Code is `available`. If it fails, retain the state
message and S3 validation logs. Do not use an older matrix-only AFI.

## Run on the prepared F2

The replacement F2 `i-049c97612201b3b80` is reachable as
`ec2-user@ec2-44-204-90-121.compute-1.amazonaws.com`. Its FPGA SDK and
Python test environment are installed; the 49 host/program tests pass.
The validated tar has been copied to `/home/ec2-user/openjev_full_model_v13.Developer_CL.tar`
and its SHA-256 matches the builder. IAM profile attachment is verified. Both hardware smoke tests and both full-model executions completed;
see measured results below. The paths below refer to the restored builder artifacts.
Loading the AFI replaces the design in FPGA slot 0. Use its returned global
`agfi-...` ID:

```bash
sudo fpga-load-local-image -S 0 -I REPLACE_WITH_AGFI_ID
sudo fpga-describe-local-image -S 0 -H
cd /home/ec2-user/model_on_hardware
sudo env PYTHONPATH=full_model/program:. /home/ec2-user/openjev-env/bin/python full_model/program/run_core_smoke.py /home/ec2-user/openjev-v13-smoke
```

Confirm the new image is loaded, then require both smoke runs to pass before
running the complete graph:

```bash
sudo env PYTHONPATH=full_model/program:. /home/ec2-user/openjev-env/bin/python full_model/program/run_fpga_benchmark.py /home/ec2-user/openjev-full-program-recovered /home/ec2-user/openjev-recovered-hbm /home/ec2-user/openjev-processor /home/ec2-user/openjev_hbm_loader /home/ec2-user/openjev-v13-results
```

The runner verifies bank readback, image identity, graph completion and finite
classification outputs. Results appear in `openjev-v13-results/results.json`,
or a per-request failure JSON. Input processing and output decoding are CPU
work; learned model inference has no CPU fallback. The checkpoint is quantized.
Independent numerical references must match the current program/manifest and
inputs; the recovered program retains the builder reference files. The earlier
CPU reference discrepancy remains documented in MODEL_INTEGRATION.md. Finite
probabilities alone do not establish model correctness. Neither GPU speedup,
video throughput nor safety certification has been demonstrated.

## Active hardware test job

`/home/ec2-user/test-openjev-v13.sh` runs the AFI load, smoke tests and full
benchmark in order, stopping on any failure. Status is in
`/home/ec2-user/openjev-v13-test-status.txt`; logs are in
`/home/ec2-user/openjev-v13-test.log`. Do not start a duplicate hardware test
while this job is active. All 32 bank hashes, compiled program binaries and
both input/reference provenances passed preflight checks.

## Completed hardware test — September 24, 2026

Both complete model requests finished on v13 with no CPU model fallback.
Each retired 1,290 instructions (the graph also includes END). Both synthetic
smoke runs passed. Raw evidence: [full-model results](sim/validation/model-integration/v13/full-model-results.json).

| Input | FPGA cycles | Start-to-completion (ms) | Request latency (ms) | Maximum logit error | Maximum probability error |
| --- | ---: | ---: | ---: | ---: | ---: |
| Box Runner | 674725510056 | 2698903.331 | 2699046.412 | 0.270663 | 0.016018 |
| Doom | 675124638762 | 2700499.446 | 2700585.964 | 0.214551 | 0.022787 |

Request latency includes CPU preprocessing, transfers and FPGA execution;
195461.979 ms of initial setup is excluded. It ends before label decoding and
reference comparison. These are single runs, not latency percentiles.
Both top classes match the provisional offline CPU oracle. No numerical
acceptance threshold or native-model parity has been established, so this is
execution completion, not a model-correctness pass. See [baseline audit](BASELINE_AUDIT.md).
The v14 parallel revision is building separately; no hardware speedup is yet measured.
