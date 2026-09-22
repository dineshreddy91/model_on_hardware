> Further implementation: [tensor/HBM integration, multihead scheduling and timing work](TENSOR_INTEGRATION.md).

# Attention, gated-delta and tensor graph implementation

## Verified status

Implemented RTL arithmetic engines, a class-based graph compiler and loader,
and a serialized graph sequencer. This is **simulation-validated source**, not
a new deployed FPGA image or a successful full-model inference result.

The current matrix AFI cannot execute this program. No CPU fallback exists in
the loader. The graph loader rejects missing capabilities before upload.

| Test | Result |
|---|---|
| Attention | 18 commands, 2,076 values; max absolute error 9.54655234e-8 |
| Gated-delta | 7 commands, 17,253 output/state values; max absolute error 1.2101877e-7 |
| Actual attention → memory → gated-delta simulation | 12 values; max absolute error 4.25399809e-8 |
| Graph sequencer | 14 protocol/fault scenarios and reset |
| Engine watchdogs | Timeout, fault containment and reset passed for both |
| Compiler and loader | 16 tests passed |
| Full checkpoint lowering | 732 tensors, 1,291 instructions, 2,458 tensor descriptors |
| Physical FPGA execution of these additions | Not tested |
| Full-model numerical equivalence / image classification | Not tested |

The graph chain uses actual arithmetic RTL with passive testbench memory.
Its small dispatch adapter is specific to that test; it is not a production
HBM adapter. Sequencer protocol tests acknowledge commands without doing
arithmetic and are not inference tests.

## Model and numerical contract

Model revision: f004f37e52695d6ddfb914a64dbf93942839ba1e, repository
AlexWortega/openjev, folder qwen3.5-0.8b-nli-v2s-long.
Equations and layouts follow the
[Transformers 5.17.0 implementation](https://github.com/huggingface/transformers/blob/v5.17.0/src/transformers/models/qwen3_5/modeling_qwen3_5.py).

The graph uses dynamically quantized per-row INT8 activations, checkpoint
INT8 matrix weights with FP16 per-output scales, and FP32 intermediates.
This differs from BF16 inference and requires end-to-end accuracy testing.
The compiler performs no model inference.

Attention implements one head per command, stable softmax, causal offsets,
optional binary key masks and arbitrary dimensions through 256. Its memory
adapter must implement multihead iteration and grouped-query head mapping.
All-masked rows fault. The initial graph input contract therefore requires
right padding and at least one valid initial text token; arbitrary left
padding is unsupported.

Gated-delta implements Q/K L2 normalization, scaled queries, exponential state
decay, prediction/correction, outer-product update and value projection.
It accepts log-decay g <= 0 and beta in [0,1]. State can be initialized to zero,
imported, or reused after a successful command with identical dimensions.
A full 128x128 state is exercised. Reset invalidates cached state.
The graph currently uses zero initial state and exports final state per head.

## Complete graph lowering

The class-based compiler covers:

- Patch projection, learned position interpolation, all 12 vision blocks and merger.
- Embedding and image insertion.
- All 24 text blocks: 18 recurrent and six grouped-query attention blocks.
- Final normalization, last-valid-token pooling, three-label classifier and softmax.

All 732 packed checkpoint tensors are referenced. Vision attention is noncausal;
text attention is causal with eight query heads and two KV heads. Q/gate views
use the model's interleaving within each head. Decoder RMSNorm uses 1+gamma;
gated RMSNorm uses direct gamma. Vision blocks use tanh-GELU; the merger uses
**erf-GELU**, a distinct operation.

Default profile: one 224x224 image, 196 vision patches, 49 merged image tokens,
128 text positions. No multi-image or streaming-cache graph is implemented.
Host preprocessing must supply correctly ordered patch pixels, token IDs,
image slots, interpolation indices/coefficients, rotary cos/sin, a key mask and
the last valid token index. Learned operations are represented in the FPGA
graph. Input preprocessing and content validation are not yet implemented.

LifetimeAllocator reuses scratch space only after the final source read.
Independent live-allocation validation rejects overlapping physical ranges.
Weights occupy the protected region below 32 MiB per bank; activations start
at 32 MiB. Default peak address is 0x0206e000 per bank.
Striping uses 32 banks and 256-byte bursts.

## Program ABI and execution

Tensor descriptors are 128 bytes and contain dtype, rank, base, root, byte
offset, shape, byte strides and bank extent. Rank-five patch weights are
flattened into an equivalent [output, flattened-input] matrix view.

Instructions are 64 bytes:
opcode/flags, tag, two destination IDs, six source IDs, five parameters, XOR
checksum seeded by 0x4f4a5031. Absent tensor IDs are 0xffffffff.
END is opcode 255. The XOR checksum detects some accidental corruption;
it does not authenticate programs.

The sequencer preflights the entire loaded instruction range before dispatch:
presence, checksum, tags, operand bounds, capability mask and final END.
Dispatch is serialized. The engine completion contract requires committed
output writes before completion; timeout or an unexpected tag causes a sticky
fault requiring reset. Default capability mask is zero.

ProgramLoader checks SHA256 artifact integrity, exact agreement between
JSON and binary tables, memory/dataflow validity, ABI, weight identity and
all required operations before any upload. Its backend is an abstract FPGA
I/O interface. There is no implementation advertising the current matrix AFI
as compatible. Capability checks are necessary but do not replace per-op
descriptor validation inside hardware adapters.

## Remaining integration

This graph is a complete *lowering*, not a complete working FPGA datapath.
Required work before a new full-model AFI test:

1. Implement tensor-table/HBM adapters, strided reads, per-head iteration,
   state export and commit acknowledgments for these engines.
2. Implement and connect all graph operations, including quantization,
   embedding/interpolation, rotary positions, causal depthwise convolution,
   softplus and exact merger erf-GELU. Existing scalar/vector primitives are
   not automatically complete graph-operation adapters.
3. Validate every operation's geometry, dtype, broadcasts and parameters at
   the hardware boundary, and validate host preprocessing.
4. Pipeline the shared FP32 arithmetic and close timing. The prior vector
   OOC result failed a 4 ns clock by 7.691 ns; these new engines reuse that
   arithmetic. They have not undergone Vivado synthesis or place-and-route.
5. Compare full graph outputs with an independent quantized reference and
   assess accuracy against the pretrained model using Doom/Box Runner images.
6. Build, register and load a compatible AFI, verify real image inference,
   and measure latency, throughput and cost against an actual GPU baseline.

No safety certification or safety control suitability is established by these
tests. The model is a three-label NLI classifier, not a validated distance
estimator or certified safety controller.

## Reproduction

From the repository root:

    bash full_model/sim/run_attention_delta_graph.sh /tmp/openjev-operator-tests
    PYTHONPATH=full_model/program python3 -m pytest -q full_model/program/tests
    python3 full_model/program/compile_program.py full_model/sim/validation/vector-scheduler/model-config.json full_model/hbm_manifest.json /tmp/openjev-program

Python requires Pydantic 2 and pytest for compiler tests. RTL simulation uses
Icarus Verilog. No model weight download, cloud provisioning or hardware
reprogramming is performed by these commands.
