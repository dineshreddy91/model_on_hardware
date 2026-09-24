# Full-model integration status

The full 1,291-instruction OpenJEV graph has a hardware dispatcher for all 23
compute opcodes and a host benchmark runner. **No complete-model FPGA result
or latency has been measured yet.** As of September 23, the v13 physical build
has completed on builder `i-0d924d0c09281d49e` at `3.88.106.252`. The previous v12
routed checkpoint failed setup timing (WNS -0.155 ns) and must not be submitted
as an AFI. The current F2 `i-049c97612201b3b80` at `44.204.90.121`
has the v13 AFI loaded and both hardware smoke runs passed. The full-model
Box Runner test is in progress, with Doom queued. Recovered weights and sources
are retained on builder EBS. The older instance/address references below are
historical build records, not current connection instructions.
The pinned original checkpoint SHA-256 is
`cf6d62a341c0c804f9a926eec71aefc9859adb28978736e757b49bce35d9b8f8`.

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

## v9 timing repair

The resumed v8 route completed with all 209,965 routable nets connected and
zero routing errors, but failed setup timing: WNS -0.955 ns, TNS -27962.213 ns,
and 98,435 failing endpoints. Hold slack was +0.006 ns. The checkpoint is
marked VIOLATED and must not be registered as an AFI.

The v9 recurrence state memory uses a bounded registered read address and two
read-pipeline registers so Vivado can infer block RAM. A stepped state offset
replaces repeated key-index multiplication in state reads/writes. Export waits
for the read pipeline and remains stable under output backpressure. Arithmetic,
external graph ABI and requested clock frequencies are unchanged.

The attention/recurrence regression passes, including 17,253 recurrence values,
state import/reuse/export, stalls, invalid inputs, memory faults, reset and
watchdogs. These are simulation results; physical timing closure remains pending.

Final v9 targeted synthesis on the shell's `xcvu47p-fsvh2892-2-e` part
reports +0.164 ns setup slack and +0.043 ns hold slack at 4 ns, 3,670
LUTs and 14.5 block-RAM tiles for the recurrence kernel. Vendor shell
simulation passes repeated requests and numerical comparison. The full
physical rebuild is staged at `/home/ubuntu/openjev-full-shell-v9/cl_dram_hbm_dma`;
its routed timing, not this standalone result, remains the deployment gate.

## v10 attention memory pipeline

The v9 physical route improved setup slack to -0.378 ns (TNS -506.676 ns),
with positive +0.006 ns hold slack, but still produced a VIOLATED checkpoint.
It has not been deployed. The v10 attention score store now uses registered
block-RAM reads; mask bits are sampled in the same pipeline. Exponentiation,
probability normalization and value accumulation wait for the selected score.
No timing exceptions or clock changes are introduced. Attention, recurrence,
graph-chain, fault and watchdog regression tests pass. Physical closure is
still required before claiming a deployable full-model AFI.

## v11 physical timing repair

The v10 full route finished with WNS -0.232 ns, TNS -154.223 ns and
WHS +0.001 ns. Its checkpoint is marked VIOLATED and has not been deployed.
The worst reported setup path spends about 81% of data-path delay in routing.
A separate post-route fanout-optimization and rerouting attempt is staged at
`/home/ubuntu/openjev-v11-route-repair`, starting from the preserved v10
checkpoint. RTL, clock frequencies and timing exceptions are unchanged.
It records critical endpoints and requires final setup/hold timing, routing,
DRC, bus-skew and unconstrained-path review before any deployment.

## v12 image-map timing repair

The v11 post-route repair ended at -0.192 ns WNS, -119.567 ns TNS,
1,785 failing setup endpoints, and no failing hold endpoints. Extracted
critical endpoints identify instruction-register fanout into the table
operator's 4,096-bit occupied vector and image-map write logic.

The v12 RTL removes the occupied vector. Each image-insertion command
clears its active map entries to the existing empty sentinel; slot validation
checks that sentinel before writing a mapping, retaining duplicate rejection.
The map uses bounded addresses and a two-register block-RAM read pipeline for
both slot validation and per-token lookup. Clocks and timing requirements
remain unchanged. Physical timing closure is still required.

## September 23: v13 timing repair

The v12 routed endpoint report identified a recurrence address multiplier,
vector operand-buffer control paths, and descriptor-valid reset fanout among
the failing endpoints. v13 replaces token-index multiplications in attention
and recurrence with running base addresses, and replaces the vector unit's
asynchronous operand/work memories with synchronous block RAM. Loads commit
through a registered stage; consumers honor `input_ready`. A softmax state
selection error introduced during this refactor was caught by numerical tests
and corrected before the physical build was launched.

At the actual -2-e device grade and a 4 ns standalone synthesis constraint,
head dispatch reports +1.268 ns setup slack and the 8192-element vector unit
reports +1.293 ns. The vector unit uses 30 block-RAM tiles, 2815 LUTs, and zero
LUTs as memory. These are synthesis estimates, not routed timing closure.
The remaining descriptor-valid reset paths must be checked in the new route.

Attention, recurrence, vector/HBM, and complete integration regressions pass.
The integration suite verifies 13,523 row outputs, 30,515 table outputs,
6,210 matrix outputs and 49 Python tests. The final Vivado shell simulation
passes the synthetic seven-instruction graph and independent output comparison
(110,079 simulated cycles). This is not a complete-model hardware benchmark.
Evidence is retained under `full_model/sim/validation/model-integration/v13/`.

The full build is in `/home/ubuntu/openjev-full-shell-v13/cl_dram_hbm_dma`;
its launch log is `/home/ubuntu/openjev-full-shell-v13-build.txt`. Next gates:
inspect routed setup/hold, route status, bus skew and DRC; create and load an
AFI only from an accepted checkpoint; run the physical core smoke test; then
execute both complete image requests, recording FPGA cycles, request latency,
instruction retirement and comparison with the offline numerical oracle.

The v13 build completed at 17:48 UTC on September 23. Independent validation
passes setup, hold, routing and bus skew with zero DRC errors. The AFI is available and loaded; the full-model test is running. See [F2 v13 testing handoff](F2_V13_TESTING.md) for measured
build results, remaining warnings, artifact location and execution commands.
