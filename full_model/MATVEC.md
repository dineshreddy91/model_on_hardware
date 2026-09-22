# Streaming matrix engine

Implemented components:

- `rtl/openjev_int8_matvec.sv`: loads one INT8 activation vector into synchronous
  block RAM, reuses it across matrix rows, multiplies 32 lanes, reduces with a
  balanced tree, and emits signed INT32 row sums with ready/valid backpressure.
- `rtl/openjev_hbm_weight_reader.sv`: translates a contiguous tensor stream into
  bank-local reads for the existing 32-bank, 256-byte striped memory format.
  Invalid commands are rejected; non-OK memory responses latch a fault until reset.
- `tools/make_matvec_fixture.py`: exports real quantized matrices and an INT64
  PyTorch reference using deterministic synthetic activations. Optional HBM input
  verifies tensor hashes and every tensor byte against the checkpoint.

## Verified results

Vivado 2025.1 simulations, 2026-09-21 UTC:

| Matrix | Shape | Real matrix rows matched |
| --- | --- | --- |
| Language layer 0 `linear_attn.in_proj_qkv.weight` | 6144 x 1024 | 6144 / 6144 |
| Vision block 0 `mlp.linear_fc2.weight` | 768 x 3072 | 768 / 768 |

Both tests connect the HBM reader directly to the compute engine through
ready/valid signals. The memory model checks every requested bank and address
against an independent arithmetic mapping and injects request and response
delays. The result consumer stalls each output. An additional 18 synthetic rows
per run cover widths 1, 31, 32, 33, 65, 127, and 4096, nonzero tail padding,
signed extrema, back-to-back commands, invalid dimensions, and resets during
computation and while a result is held. These tests are raw integer arithmetic
tests, not image-level model accuracy tests.

The separate reader test passed 1294 transfers across all banks and multiple
stripes, bounds rejection, output backpressure, and all three non-OK response
codes. Both real matrices also match the saved HBM images byte-for-byte and by
the manifest SHA-256, at bank-local bases `0x7a1000` and `0x1809000` respectively.

Standalone synthesis for `xcvu47p-fsvh2892-2L-e` succeeded:

| Component | LUTs | Registers | BRAM tiles | DSPs | Estimated WNS at 4 ns |
| --- | ---: | ---: | ---: | ---: | ---: |
| Matrix engine | 3744 | 1056 | 4 | 0 | +1.198 ns |
| HBM reader | 141 | 351 | 0 | 0 | +2.138 ns |

Vivado mapped these small multipliers into LUTs. These are synthesis estimates
with no placement, routing, shell clock skew, or external I/O constraints. They
do not establish timing closure or throughput on F2. Subsequent shell integration
closed routed timing and passed hardware testing; see
[the HBM hardware record](../aws_f2/hbm_matvec/validation/NEW_INSTANCE.md).

## Reproduce

Use the same quantized checkpoint that generated `hbm_manifest.json`, an
environment containing PyTorch and safetensors, and Vivado 2025.1 on PATH.

```bash
python full_model/tools/make_matvec_fixture.py \
  /path/to/openjev-0.8b-int8.safetensors \
  model.language_model.layers.0.linear_attn.in_proj_qkv.weight \
  /tmp/matvec-qkv /path/to/hbm
bash full_model/sim/run_matvec.sh /tmp/matvec-qkv

python full_model/tools/make_matvec_fixture.py \
  /path/to/openjev-0.8b-int8.safetensors \
  model.visual.blocks.0.mlp.linear_fc2.weight \
  /tmp/matvec-vision /path/to/hbm
bash full_model/sim/run_matvec.sh /tmp/matvec-vision

# From a separate build directory, using the absolute source script path:
vivado -mode batch -source /path/to/model_on_hardware/full_model/sim/synth_matvec.tcl
```

## Interface and integration limits

The default compute configuration supports 1–4096 columns. It ignores padded
lanes on partial input words. The reader operates on unpadded contiguous tensor
bytes, so a directly connected matrix must have a column count divisible by 32.
The reader requires a 4 KiB-aligned bank-local base and a positive byte count
divisible by 32. It rejects transfers extending beyond 512 MiB per bank.

A command is accepted on `command_valid && command_ready`. Load all activation
words, then stream weights row-major. Results remain stable until accepted;
`done` pulses after the last output handshake. Integer results need the model's
activation/weight scales and any bias applied by the future vector unit.

The HBM adapter must route each reader request to the selected pseudochannel as
a single 32-byte read, then return one response, with errors translated into
`response_status`. This module is a request/response client, not a complete AXI
master. No physical HBM, AXI routing, clock-domain crossing, or DMA is simulated
here. Reset recovery requires draining or resetting the memory adapter as well
as resetting these modules, to prevent old responses reaching a new command.

The reader permits only one outstanding read, and the compute engine takes four
cycles per weight word before result handshaking. Multiple outstanding reads,
prefetching, parallel output rows, and pipelining are needed for competitive
throughput. No GPU performance claim follows from these correctness tests.

The subsequent HBM shell milestone is complete: command/status registers,
timeout handling, physical HBM weight upload/readback, and both real matrices
passed on a new AFI with three runs each. The initial single-outstanding-read
architecture still needs burst prefetching and parallel execution for speed.
Full-model inference additionally needs vector/scaling operations, vision
embedding, attention, gated-delta state, and the full graph scheduler.
