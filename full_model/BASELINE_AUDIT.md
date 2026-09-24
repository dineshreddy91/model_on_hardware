# Baseline audit — September 24, 2026

Verdict: a provisional quantized-graph reference exists, but a complete validated
model-correctness and performance baseline has not been established.

## Verified

The active reference files on the F2 match pinned model revision
f004f37e52695d6ddfb914a64dbf93942839ba1e and the recovered HBM manifest.
Preflight checked both images' 11 input tensor hashes against these references,
all 32 HBM bank hashes, the compiled binaries, and model configuration.
The separate CPU reference evaluates quantized graph operations in PyTorch;
it is not CPU fallback in the FPGA benchmark. Hardware smoke tests passed.

## Gaps

- The reference executes the same compiled graph as the FPGA. Independent
  operator arithmetic cannot detect all shared graph/compiler errors.
- Retained earlier and recovered CPU references disagree: maximum logit
  differences 0.4190223217 (Box Runner) and 0.0724272728 (Doom). The cause is
  unresolved. Both active references lack reference_environment metadata.
- The native-model calibration artifact is not a matched two-image baseline:
  its script uses a different hypothesis and input construction. Native pinned
  checkpoint inference with exactly the benchmark processor inputs is needed
  to isolate compiler changes and quantization error. Task prompt/template
  semantics also require validation against the checkpoint's intended usage.
- OfflineReference.compare reports max error, RMSE and class agreement, but
  has no numerical acceptance threshold. A completed benchmark is not a
  correctness pass. Do not select thresholds after inspecting FPGA results.
- There is no matched GPU latency/cost measurement (deferred by user), no
  repeated warm-run distribution, and only one request per image in this run.
- The request timer includes preprocessing, input/output transfers and device
  execution, but stops before label decoding/reference comparison. It excludes
  initialization, weight loading and configuration. Report these boundaries
  explicitly; do not describe it as camera-to-action latency.
- Two gameplay screenshots cannot establish video, safety or detection accuracy.

## Required before claiming a correct or competitive full model

1. Reproduce the quantized reference with recorded source, graph, checkpoint,
   dependency and CPU-backend provenance, preserving both existing references.
2. Resolve the reference discrepancy and compare against native checkpoint
   execution on identical processor inputs; isolate graph and quantization loss.
3. Define numerical and task-level acceptance criteria and expand the test set.
4. Compare FPGA outputs with that validated reference. Later measure repeated,
   identically scoped GPU/FPGA requests and actual instance costs.

The active FPGA test was left unchanged so its original evidence is preserved.
