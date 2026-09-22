> Further implementation: [tensor/HBM integration, multihead scheduling and timing work](TENSOR_INTEGRATION.md).

# Vector operators and descriptor scheduler

These RTL modules implement a tested command-to-HBM-vector-result path. They
are not yet part of the registered AFI and do not execute the complete OpenJEV
graph. CPU code in the tests supplies independent references, never arithmetic
for the running RTL datapath.

## Implemented data path

`openjev_command_scheduler` validates and holds one descriptor, dispatches it,
checks the engine response, then holds completion until its consumer accepts it.
`openjev_hbm_vector` fetches 32-byte striped HBM words, streams FP32 operands to
`openjev_vector`, and packs the outputs for `openjev_hbm_activation_writer`.
Completion requires both vector completion and acknowledged HBM writeback.
The final word is zero-padded to 32 bytes; allocation must include that padding.
Other bytes in the same 64-byte AXI beat are preserved by byte strobes.

`openjev_vector` supports up to 4096 elements. `openjev_scalar` sequences
arithmetic through a shared add/multiply datapath. Operand preparation,
arithmetic, and consuming/converting its result occur in separate cycles. The FP32 package implements
round-to-nearest, ties-to-even and gradual underflow using integer logic.
No `real`, `shortreal`, host RPC or simulation-only floating-point conversion is
used in the synthesizable modules.

| Opcode | Operation | B/C operands |
|---|---|---|
| 0 | FP32 add (bias/residual) | B |
| 1 | FP32 multiply (scaling/gating) | B |
| 2 | exp | unused |
| 3 | reciprocal | unused |
| 4 | inverse square root | unused |
| 5 | sigmoid | unused |
| 6 | SiLU | unused |
| 7 | GELU with tanh approximation | unused |
| 8 | RMSNorm | B is effective gamma; C ignored |
| 9 | LayerNorm | B gamma, C beta |
| 10 | stable softmax | unused |

Norms use a strictly positive finite epsilon. LayerNorm computes the mean then
centered variance, not `E[x²] - E[x]²`. Softmax subtracts the maximum before exp.
RMSNorm expects the effective multiplier: Qwen layers using `1 + weight` need
that addition in their graph. Gated RMSNorm also needs a separate SiLU/multiply.
GELU opcode 7 specifically implements the tanh variant, not the exact erf form.

## Numeric contract

Addition/multiplication have 120,156 bit-exact reference cases, including signed
zero, cancellation, overflow and subnormals. NaN/Inf inputs and nonfinite results
are reported as errors by the scalar interface. Exp accepts finite x <= 88;
values below -104 round to zero. Reciprocal rejects zero, and inverse square
root rejects nonpositive inputs. Arithmetic overflow is an explicit error.

Exp uses range reduction with split ln(2), a seventh-degree polynomial and
power-of-two scaling. Reciprocal and inverse square root use five Newton
iterations after normalization. Sigmoid uses exp(-abs(x)) for stable tails.
SiLU/GELU can underflow their exponential before multiplication by x.

Scalar reference tests require relative error <= 4e-6 (2e-5 for composed
GELU-tanh, whose rounded exponent argument amplifies relative tail errors),
with an absolute floor
of 1e-37 for underflow. Vector tests use relative/absolute 2e-5 for ordinary
operations and absolute 1e-3 for LayerNorm's cancellation-sensitive cases.
These are development test tolerances, not an established model-wide accuracy
budget or a safety guarantee. The tests report measured errors. End-to-end
checkpoint/image comparisons remain mandatory before model results are claimed.

## Descriptor and fault contract

Engines 0/1/2 denote vector/matvec/copy. The scheduler defaults to **no enabled
engines**. An integration must enable only connected engines. The integrated
simulation enables vector only; it does not claim a connected matvec or copy
engine. `command_last` marks the final descriptor and appears on completion
only after the engine acknowledges it. There is no internal program fetcher yet.

Each descriptor has a 16-bit tag, opcode, count, width, epsilon, A/B/C bases and
destination. Bases are 29-bit bank-local addresses in the existing 32-bank,
256-byte-striped layout and must be 4 KiB aligned. Destination starts at or
above `SCRATCH_BEGIN` (default 32 MiB per bank, above the current weight image).
The scheduler checks conservative allocation extents, required input ranges,
and disallows source/destination overlap. Unused source fields are ignored.
It checks matvec geometry but does not perform that engine's arithmetic.

Fault codes: 1 unsupported engine; 2 shape/opcode/epsilon; 3 range/protection;
4 overlap; 5 watchdog; 6 response identity; 7 engine failure; 8 illegal state.
The watchdog covers dispatch and execution, not consumer completion stalls.
On a fault, the surrounding shell must reset/drain this sequencer, all attached
engines and AXI adapters before accepting a new graph. Resetting only the
sequencer cannot safely discard outstanding transactions. The scheduler alone
is not a machine safety controller.

## Reproduce

```bash
bash full_model/sim/run_vector_scheduler.sh /tmp/openjev-vector-regression
```

Tests include producer/consumer stalls, invalid commands, protected regions,
aliases, missing/incorrect/error responses, reset during execution, independent
AW/W arrival, delayed B responses, all banks, stripe crossings and output guards.
The integrated tests include lengths 2057 and 4096 and inject read/write/ID faults.

Standalone VU47P synthesis uses `full_model/sim/synth_vector.tcl` from a build
output directory. This is separate from shell placement/routing and AFI creation.
Current out-of-context synthesis (Vivado 2025.2, 4 ns clock):

| Module | LUTs | Registers | DSPs | Worst setup slack |
|---|---:|---:|---:|---:|
| Scheduler, vector engine enabled | 511 | 388 | 1 | +1.430 ns |
| HBM vector path | 19,163 | 2,583 | 2 | **-7.691 ns (FAIL)** |

The scheduler's bounds calculations are registered before validation. The vector
core's remaining critical path is the arithmetic register-to-register datapath;
its 11.673 ns estimated delay needs deeper arithmetic pipelining. No multicycle
or false-path exception was added to hide this failure. These estimates are
not routed timing or measured board frequency. No new AFI was created or loaded.
Reports and source hashes are in `sim/validation/vector-scheduler/`.
The build-only instance's EBS retains `/home/ubuntu/openjev-vector-synth-v3/`.

## Still needed for full-model execution

- Physical shell routing/arbitration for this path, register/descriptor transport,
  routed timing closure, AFI creation and actual FPGA vector tests.
- Requantization and integer packing; connections between matrix sums, scales,
  biases, vector operators and activation HBM; matrix batching/tiling.
- Image/token embedding, positional interpolation, rotary operators and causal
  convolution hardware adapters; HBM integration for the now-simulated attention
  and gated-delta engines.
- Connect the new graph compiler, tensor lifetimes and sequencer to all hardware
  adapters; validate final pooling/classification and full-image accuracy.

The earlier 42-stage JSON inventory is superseded by the new 1,291-instruction
tensor graph. See [attention, recurrence and graph results](ATTENTION_DELTA_GRAPH.md)
for the tested scope and remaining physical implementation.
