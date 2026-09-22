# Tensor integration progress

This work extends the complete graph compiler with hardware memory plumbing,
multihead scheduling, registered arithmetic and missing numerical primitives.
It does not yet execute the complete model. No new AFI has been loaded.

## Implemented and verified in RTL simulation

| Component | Verified scope |
|---|---|
| Registered FP32 ALU | 120,156 bit-exact add/multiply cases; 12,060 bit-exact power-of-two scaling cases |
| HBM element port | 393 accesses; 1/2/4-byte strobes across all 32 banks; AXI stalls, protected weights, bounds and errors |
| Tensor address translator | 94 cases, including interleaved Q/gate views and rank-four strides |
| Tensor-memory composition | 393 accesses through view translation and AXI |
| Loaded tensor table | 393 accesses through tensor ID, descriptor/root lookup and AXI; configuration lock |
| Per-head dispatcher | 76 output/state values for grouped-query attention and recurrence; maximum absolute error 7.8752834e-8 |
| Softplus and erf-based GELU | 646 cases; maximum scaled errors 7.6025746e-8 and 2.1311455e-7 |
| Bounded integer conversion | All 9,216 supported inputs, bit exact |
| Rotary embeddings | Full/partial rotation; 928 bit-exact outputs, committed writes, invalid dimensions and in-place rejection |
| Causal depthwise convolution | 6,208 bit-exact outputs, including 6,144 channels; INT8/FP16 scaling, left padding, NaN and bus fault handling |
| Dynamic row quantization | 11 rows, 12,637 exact scale/INT8 results, including widths 1, 64, 1024, 3072, 3584 and 4096 |

Existing scalar, vector, scheduled-HBM, attention and gated-delta numerical
regressions also pass after moving arithmetic and exponent scaling into the
registered datapath. Testbench deadlines were increased to accommodate the
added pipeline stages; the datapath has higher cycle latency.

The per-head dispatcher consumes graph opcodes 22 and 23. It iterates heads in
FPGA logic, maps grouped queries to their KV head, and acknowledges each output
only after the memory port reports a committed write. It supports the model's
power-of-two head dimensions and power-of-two grouping ratios. Nonconforming
dimensions fault before execution.

The descriptor table uses synchronous descriptor/root reads. Reset invalidates
all entries. Configuration is disabled while run_enable is asserted. The host
must hold run_enable for the entire graph, including gaps between memory
requests. Raw values retain their declared dtype. The typed numerical adapters and
unified dispatcher are now implemented; see MODEL_INTEGRATION.md.

The AXI port uses the existing shell HBM window at 0x1000000000, 512 MiB per
bank, 32 banks and 256-byte logical striping. It never writes below 32 MiB per
bank. Fault recovery requires resetting both the client and the downstream
AXI adapter; it does not cancel an already issued external transaction.

## Numerical contracts

Softplus uses log(1+exp(x)) in a stable form, with an odd-series polynomial
for log1p. Merger GELU implements the erf-based function with an erfc
polynomial approximation, rather than substituting tanh-GELU. These are finite
FP32 approximations with a tested error bound of 2e-6 * max(1,abs(reference));
they do not promise correctly rounded transcendental results.

Row quantization emits its FP32 scale first, then INT8 values in the low byte.
For a nonzero row:

    scale = max(FP32(absmax * FP32(1/127)), minimum_normal_FP32)
    q = clamp(round_to_nearest_even(x * approximate_reciprocal(scale)), -127, 127)

A zero row uses scale 1. The finite scale floor prevents reciprocal overflow
for subnormal activations. This contract must also be used by the independent
full-graph numerical reference. The generated tests match reference rounding
exactly; arbitrary inputs extremely close to a half-integer may differ by one
quantization step because the reciprocal is approximate.

The causal convolution uses kernel order matching depthwise cross-correlation:
output[t,c] sums input[t+k-(K-1),c] * dequantized_weight[c,k] in increasing k,
with left zero padding and separate FP32 product/add rounding. Its output is
pre-SiLU. RoPE uses separate product/add rounding and split-half rotation;
partial rotation copies the remaining dimensions. Both require fresh output
storage, enforced by graph validation; direct equal input/output IDs are also
rejected in hardware. Distinct tensor IDs that alias storage require descriptor
validation before dispatch.

## Synthesis and deployment

Vivado 2025.2 out-of-context synthesis on xcvu47p-fsvh2892-2L-e now
meets the 4 ns register-to-register target for all four measured components:

| Component | Worst setup slack | Report revision |
|---|---:|---|
| FP32 ALU | +1.293 ns | v2 |
| Tensor memory | +0.393 ns | v2 |
| HBM vector | +1.293 ns | v4 |
| Head dispatch | +0.164 ns | v4 |

The initial vector result was -7.691 ns. Fixes register arithmetic, scaling,
integer conversion and address generation; no false-path or multicycle
exceptions were added. Reports are under sim/validation/tensor-integration/.
RoPE, causal convolution, quantization and the loaded descriptor table have
not yet been measured as separate synthesis tops. The OOC clocks do not
constrain external I/O, and placement/routing may change these results.

Out-of-context synthesis is not routed shell closure. No new AFI or hardware
image classification result is claimed.

## Full-model integration

The unified dispatcher, row/table adapters, batched matrix engine, program
metadata, shell register loader and image benchmark runner are implemented.
See [MODEL_INTEGRATION.md](MODEL_INTEGRATION.md) for current integrated tests
and deployment status. Remaining work includes integrated timing closure,
routed shell build, AFI creation/loading, full-model hardware execution and
independent numerical comparison. The prior matrix-only AFI cannot execute
this graph.
