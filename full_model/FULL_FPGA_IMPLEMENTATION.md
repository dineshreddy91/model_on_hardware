> Current status: [full-model dispatcher, shell and benchmark integration](MODEL_INTEGRATION.md). New RTL passes integration simulation; full-model hardware execution and latency remain unmeasured.

> Further implementation: [tensor/HBM integration, multihead scheduling and timing work](TENSOR_INTEGRATION.md).

> Update: attention, gated-delta and the complete tensor-graph lowering are now implemented and simulation-tested. See [current results and remaining hardware integration](ATTENTION_DELTA_GRAPH.md). The loaded AFI still supports matrix operations only.

# Full image inference implementation

Target: `AlexWortega/openjev/qwen3.5-0.8b-nli-v2s-long`, revision
`f004f37e52695d6ddfb914a64dbf93942839ba1e`. Inputs are the Doom and Box Runner
demo images linked from `https://zefan-cai.github.io/open-jev/`.
That site publishes a different 2B/9B model family; its benchmark scores do not
apply to this checkpoint or this accelerator.

**Full-model hardware integration is implemented in source and simulation,
but has not been deployed. No FPGA image predictions have been generated.**
Host decoding, resizing, normalization, tokenization, transfers and command
submission are allowed. Learned-layer calculations and intermediate tensor
operations must run in FPGA hardware. Offline CPU references are test oracles,
never an inference fallback.

## Verified components

| Component | Verification | Current deployment |
|---|---|---|
| INT8 matrix engine and striped HBM reader | Real QKV and vision matrix hardware tests | Existing AFI `agfi-0c98e7286f4bae29b` |
| Activation HBM writer | 322 successful writes plus rejection/fault tests in RTL simulation | Standalone RTL only |
| INT32 × FP16 weight scale → FP32 | 655,360 bit-exact independent reference vectors | Pipelined full-core simulation |
| FP32 addition/multiplication | 120,156 bit-exact vectors | RTL simulation |
| Scalar nonlinear / vector normalization / softmax | Independent numeric references and protocol tests | RTL simulation |
| Descriptor scheduler + vector HBM path | 134 scheduled commands, 8,925 output checks, injected bus faults | Integrated RTL simulation; not registered AFI |

The writer preserves adjacent 32-byte halves using AXI byte strobes. Its address
and data channels handshake independently, and bytes are counted as committed
only after a successful write response with the expected ID. It checks aligned
allocation bounds, rejects incorrect stream framing, and latches bus faults.
Reset must also reset/drain the downstream adapter. The future command scheduler
must enforce activation-region ownership and a transaction watchdog.

The scaling primitive uses integer significand arithmetic and one final
round-to-nearest-even operation. All finite INT32 × binary16 products fit the
normal binary32 range. NaN/Inf scales produce an error; they are not silently
treated as valid data. Activation scaling, bias and later normalization are
separate operations now supported by the standalone FP32 vector unit but not
connected to the matrix engine. This combinational arithmetic
has now been replaced by a registered datapath. Complete integration and current
timing status are tracked in MODEL_INTEGRATION.md.

## Remaining acceptance gates

The previously missing adapters and graph dispatch are now implemented. The
current status and reproducible tests are in [MODEL_INTEGRATION.md](MODEL_INTEGRATION.md).
Remaining gates are integrated timing closure, full shell placement/routing,
AFI creation and loading, complete-model hardware inference, and independent
numerical comparison. Latency must be measured on the resulting hardware.

## Reproduce new primitive tests

Requires Python 3 and Icarus Verilog (`iverilog`, `vvp`):

```bash
bash full_model/sim/run_full_model_primitives.sh /tmp/openjev-full-primitives
```

The numerical vectors exhaust all 65,536 FP16 encodings, with nine integer edge
cases and one deterministically random integer per encoding. Python binary64
represents each finite product exactly before binary32 packing. The RTL test
also exercises input handshakes, output stalls, reset, and nonfinite errors.
The writer test covers all banks, stripe transitions, both write halves, both
AW/W arrival orders, delayed/error responses, invalid bounds and framing.

## Hardware availability

During this implementation, SSH to `35.175.208.193` began timing out. A refreshed
EC2 console confirmed `i-0bb375888c477ede7` was **Terminated**. No termination
command was issued by this task. The termination cause and EBS retention have
not been established. The earlier FPGA Developer builder was stopped deliberately
after its completed build and is a different instance.

Local source, prior hardware reports and the registered AFI remain available.
The user supplied replacement F2 `i-08d637784fd83abd2` at
`ec2-35-175-138-254.compute-1.amazonaws.com`. SSH uses `ec2-user`, not `root`.
The existing `ModelOnHardwareFpgaProfile` was attached with user approval, and
STS verified the instance assumed `ModelOnHardwareFpgaRole`. AWS FPGA SDK
revision `b603a81f65666e0cf7a67ee5cf18b148eb6b08c3` installed successfully.
The existing HBM image `agfi-0c98e7286f4bae29b` loaded successfully in slot 0,
with shell `0x10212415` and device `1d0f:f001`. This is a restore of the matrix
accelerator, not a new full-model AFI. The supplied replacement is a Spot
instance. Source is retained locally and on its EBS volume.
Replacement hardware alone does not complete the missing model operators above.

The replacement reproduced all 732 quantized tensor hashes and packed
923,140,096 bytes across 32 bank images. Three QKV runs matched all 6,144 outputs
each, and three vision FC2 runs matched all 768 outputs each. Both weight
uploads passed readback across all 32 banks. Host start-to-done measurements
were approximately 64.1 ms and 25.7–25.8 ms respectively, excluding weight upload
and result readback. These use synthetic activations and real weights, not
the benchmark images. Evidence is in
`../aws_f2/hbm_matvec/validation/replacement-i-08d637784fd83abd2/`.
