# Full-model integration status

The full 1,291-instruction OpenJEV graph has a hardware dispatcher for all 23
compute opcodes and a host benchmark runner. **No complete-model FPGA result
or latency has been measured yet.** The previous F2 ran a matrix-only AFI;
the new runtime refused that identity before writing model data. AWS terminated
Spot instance `i-08d637784fd83abd2` at 2026-09-22 20:48:18 UTC with
`Server.SpotInstanceTermination`. Its root volume is no longer in the EBS
inventory. The separate `r6i.xlarge` builder `i-0d924d0c09281d49e` remains
running, with sources and the active physical build intact. The user will
provide a replacement F2 endpoint. Recovery on the builder's EBS disk reproduced
all 732 tensor hashes and all 32 HBM-bank hashes. The pinned original checkpoint
SHA-256 is `cf6d62a341c0c804f9a926eec71aefc9859adb28978736e757b49bce35d9b8f8`.

The CPU handles image decoding/resizing, tokenization, input coordinates,
PCIe transfers/control, and label decoding. No learned inference executes on
the CPU in this runner. The graph targets the pinned 0.8B checkpoint revision
`f004f37e52695d6ddfb914a64dbf93942839ba1e`, with 224×224 images and 128 text
slots. This is a single-image classification test, not video throughput.

## Implemented

- Typed row operators: quantization, dequantization, normalization, elementwise
  arithmetic, activations and softmax.
- Embedding, four-corner positional interpolation, image insertion and pooling.
- Batched INT8 matrix execution with striped HBM weights and committed outputs.
- Rotary embeddings, causal convolution, attention and gated-delta scheduling.
- Unified graph dispatch, descriptor/metadata tables and shared AXI arbitration.
- F2 shell register protocol, complete-record checks and active-program locking.
- Class-based input preparer, device runtime and Doom/Box Runner benchmark.

The model is quantized; it does not promise bit-identical native checkpoint
outputs. An independent offline CPU graph oracle has produced reference outputs for both
images. Comparison against FPGA outputs remains required.

## Verification

`bash full_model/sim/run_model_integration.sh OUTPUT_DIRECTORY` runs:

- 655,360 exact INT32×binary16 conversion cases, including every binary16
  pattern, extremes, ties-to-even, errors and output backpressure.
- 19 row-operator cases with 13,523 outputs; maximum scaled error 6.865e-7.
- 15 table-operator cases with 30,515 bit-exact outputs.
- 6,210 exact batched matrix outputs, stalls, striped banks and bounds.
- A synthetic seven-instruction graph through the real dispatcher and AXI
  tensor/weight path, compared against independent numerical expectations.
- 49 compiler, metadata, host protocol, hardware-fixture and numerical-reference tests.

The small graph also passed the Vivado simulation of the F2 host-register
wrapper. These are simulations, not full-model hardware results. The earlier
individual operator regressions remain available in the other simulation
runners.

Integrated Vivado synthesis at a 4 ns target exposed a head-address path and
then a dequantization path (v2 WNS −4.377 ns). Registered table addresses
improved WNS to −0.766 ns in v4. Convolution addressing and INT8 rounding
were subsequently pipelined and passed their numerical tests. Registered
instruction fetch in v6 moved the program into block RAM, but standalone WNS
remains −0.414 ns through instruction validation. This is not timing closure.
The physical synthesis result and routed shell timing must be checked before AFI
creation. The first shell attempts exposed missing AWS macro includes. The v6 build
adds explicit headers and registered instruction fetch; its encrypted BuildAll
job passed shell synthesis with zero errors and zero critical warnings. Its
post-optimization shell report has +0.067 ns setup slack at 4 ns; placement
completed with a reported −1.735 ns WNS. Physical optimization and routing
remain necessary. This is not evidence of successful
routing or deployment. No timing exceptions were introduced to hide these paths.

The subsequent v7 instruction pipeline registers the RAM output and preflight
decision separately. Its standalone 4 ns synthesis has +0.170 ns WNS, zero
setup failures and zero hold failures. Sequencer fault tests and two consecutive
integrated graph executions pass. The v8 source also serializes descriptor and
root-descriptor reads through one block-RAM port, with separate output registers.
The tensor-port regression passes 393 accesses across all 32 banks, including
bounds, protection, stalls and faults; repeated integrated graph outputs remain
correct. Combined v8 standalone synthesis also passes at 4 ns (+0.170 ns WNS,
zero setup/hold failures), using 114,082 LUTs, 48,448 LUTs as memory and 133
block-RAM tiles. The v6 baseline used 199,113 LUTs. Vendor shell simulation
passes both repeated requests and numerical comparison. The superseded v6
physical job was stopped after retaining its placed checkpoint and timing
reports; it never produced a routed result. The replacement physical build
uses `/home/ubuntu/openjev-full-shell-v8/cl_dram_hbm_dma`.

On September 22, v8 completed shell synthesis with zero errors and zero critical
warnings, linked into the shell, completed optimization and entered placement.
The post-optimization setup report has +0.067 ns slack at 4 ns. The pre-optimization
DRC reported zero errors, with the vendor caveat that abstract-shell checks do
not cover every connectivity rule. Final placement, routing, timing and DRC
validation are still pending. The builder at `34.207.149.68` is an r6i.xlarge,
not an F2; a replacement F2 endpoint is required for hardware execution.

The checkpoint and all 32 bank images were recovered on builder EBS with
verified tensor and bank hashes. Recompiled program and descriptor binaries
match the retained originals. The regenerated CPU oracle differs from the
retained F2 CPU oracle despite identical input bytes and weights: maximum
logit differences are approximately 0.4190 for Box Runner and 0.07243 for
Doom, with unchanged top classes. One versus eight CPU threads produces
identical outputs on the builder, so thread count does not explain the
difference. The cause remains unconfirmed; both baselines must be retained
and numerical differences reported rather than assuming bitwise parity.
These are offline CPU validation results, not FPGA inference results.

## Deployment and measurement

`aws_f2/build_openjev_full_model.sh` stages a distinct CL directory, copies the
existing HBM shell and full-model wrapper, and reads the FP32 package before
its users. Set `AWS_FPGA_REPO` and `OPENJEV_CL_DIR` for the builder. Successful
out-of-context synthesis is not a replacement for shell placement/routing.

After the new AFI is available and loaded, use the pinned CPU preprocessing
dependencies in `benchmark/requirements-input.txt` and run from the repo root:

```bash
sudo env PYTHONPATH=full_model/program:. /path/to/python \
  full_model/program/run_fpga_benchmark.py \
  /path/to/program /path/to/hbm /path/to/processor \
  /path/to/openjev_hbm_loader /path/to/results
```

Before loading the full checkpoint, `full_model/program/run_core_smoke.py
OUTPUT_DIRECTORY` uses the same device interface to run the independently
checked synthetic graph twice. It writes small fixture weights to HBM; the
full-model runner subsequently replaces them with the complete checkpoint.
This check is explicitly labelled as synthetic and cannot count as a model result.

The runner uses explicit PCI BAR4 transfers for weights. The installed AWS HDK
documents that F2 Small Shell has no built-in DMA engine. Binding an XDMA
driver to this CL's PCI ID did not provide one: its first 4 MiB request timed
out in both interrupt and polling modes. No XDMA driver is needed on the
replacement host. The previous unload attempt did not reach the terminated host.
An actual PCI transfer verified all 923,140,096 bytes on the existing matrix
AFI. That is memory validation, not a model prediction. The PCI loader uses
write combining, an explicit x86 store fence, and complete
64-bit readback verification. This is CPU transfer work, not CPU inference.

The runner validates graph and weight checksums, verifies all loaded HBM banks,
loads the graph, and records CPU preprocessing, input transfer, FPGA completion,
output transfer, device cycles and request wall time. Weight/program setup is
reported separately. A result requires complete instruction retirement and
finite normalized classification probabilities. If references are present under
`PROGRAM_DIR/references/{box_runner,doom}.json`, it verifies their input hashes
and reports absolute error, RMSE and argmax agreement. These metrics alone do
not establish safety accuracy. It never substitutes CPU model execution after a device error.

Images originate from the OpenJEV benchmark website. The Box Runner image
includes an action overlay and is not an independent safety-accuracy test.
No GPU speedup or UL 3300 certification is established by these examples.

## September 22 publication regression

The integration script was rerun before publication: binary16 conversion and
655,360 scaled-integer vectors passed, row/table/matrix operators passed, and
the repeated synthetic AXI graph matched its independent numerical reference.
All 49 Python compiler/runtime/reference tests passed. The complete transcript
is [publish-regression.txt](sim/validation/model-integration/publish-regression.txt).
This regression is simulation and host testing, not the requested full-model
FPGA hardware benchmark. That benchmark awaits a routed, validated AFI and a
replacement F2 instance.
