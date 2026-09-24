# Virtual end-to-end validation — September 24, 2026

The exercised v14 RTL paths pass the current functional simulation checks.
This is **not a complete 0.8B model RTL simulation, a timing simulation, or a
proof of fast full-model inference**. The physical v14 build still fails setup
timing and must not be deployed on the strength of these simulations.

## Integrated graph and memory-delay comparison

The actual model core runs a seven-operation synthetic graph: embedding,
normalization, quantization, matrix multiplication, rescaling, last-token gather
and softmax. It executes through the program sequencer, operator dispatcher,
tensor descriptors, striped AXI memory, and committed output writes. Memory is
a behavioral model; it does not reproduce the vendor HBM controller or shell.
Two consecutive runs check restart behavior. Configuration stays locked while
active and graph completion requires memory transactions to have completed.

Both revisions use the same updated testbench, fixtures and deterministic bus
stalls. The serial source is commit `a78fba2`; v14 RTL is from `3a92200`.
Every captured intermediate tensor and final output matches bit-for-bit between
revisions. Final values also pass the independent fixture equations at a scaled
2e-5 tolerance. The graph does not contain attention or gated-delta; those are
exercised separately below. This graph primarily measures the read-buffer effect.

First-run measurements (the second run agrees within six cycles):

| Added AXI read delay | v13 cycles | v14 cycles | Cycle speedup |
| ---: | ---: | ---: | ---: |
| 0 | 110070 | 110560 | 0.996x |
| 16 | 123156 | 120711 | 1.020x |
| 64 | 162010 | 150565 | 1.076x |

AXI transactions decrease from 1128 to 943 per request (16.4%). At zero added
latency, the cache lookup overhead makes this graph about 0.45% slower. There
is no claim that all workloads improve. Cycle counts exclude loading fixtures.

## Attention, recurrence and broader checks

- Four-lane attention versus the original serial implementation: identical bits
  across 30 commands / 7668 outputs. Multiquery aggregate cycle speedup is
  1.537x at a fixed 64-cycle response delay, with backpressure. This is an
  attention microbenchmark, not end-to-end model speedup.
- Attention versus binary64 equations: maximum absolute error 6.61029001e-7.
- Gated-delta: 7 commands / 17253 values, maximum absolute error 8.55575323e-8;
  state import/reuse/export, stalls, faults and reset pass.
- Sequenced attention -> stored tensor -> gated-delta: 12 committed values,
  maximum absolute error 4.25399809e-8.
- Matrix: 6210 exact INT32 outputs; row quantization: 12637 exact outputs;
  tensor addressing, all 32 banks, write strobes, bounds, read/write stalls,
  watchdogs, sticky faults, numerical-domain errors and reset checks pass.
- Host/compiler/reference tests and comparison-report tests: 53 pass.

Raw logs, per-case cycles and source hashes are in
[`sim/validation/virtual-e2e-v14/`](sim/validation/virtual-e2e-v14/).
These are deterministic fixtures, not randomized formal verification or
exhaustive coverage of every tensor shape.

## Reproduce

Create an isolated copy of the serial source without altering your checkout:

```bash
mkdir -p /tmp/openjev-serial-source
git archive a78fba2 full_model | tar -x -C /tmp/openjev-serial-source
bash full_model/sim/run_virtual_core_comparison.sh /tmp/openjev-serial-source/full_model /tmp/openjev-core-comparison
bash full_model/sim/run_parallel_attention.sh /tmp/openjev-attention-comparison
bash full_model/sim/run_model_integration.sh /tmp/openjev-model-integration
bash full_model/sim/run_attention_delta_graph.sh /tmp/openjev-operators
bash full_model/sim/run_tensor_integration.sh /tmp/openjev-tensors
```

## What remains unproven

The real full model previously took roughly 675 billion FPGA cycles per image
on v13. These reduced fixtures do not execute its entire 1291-instruction graph,
full weights or Doom/Box inputs. The provisional full-model CPU comparison also
has unresolved numerical differences. Simulation passing here does not resolve
that baseline issue, establish GPU competitiveness, or validate camera safety.

Before measuring v14 on F2, fix its HBM write-control setup violation and obtain
a clean routed checkpoint. Then use the same full-model images, weights and
program to measure actual numerical differences and request latency. Larger
matrix/recurrent parallelism remains necessary for substantially faster inference.
