# v14 parallel-compute revision

Status: full shell build completed September 24 at 05:40 UTC after 1h33m,
but **failed routed setup timing and is rejected for AFI submission/testing**.
Independent checkpoint inspection reports WNS -0.111 ns, TNS -16.674 ns,
335 failing setup endpoints; hold +0.010 ns with zero failing endpoints.
All 190,227 routable nets are routed with zero routing errors. All ten bus-skew
constraints pass (minimum +2.730 ns). DRC has zero errors, 190 warnings and
one advisory. Raw reports are in `sim/validation/parallel-v14/routed/`.

The worst reported path is the 450 MHz HBM WREADY-to-write-payload clock-enable
path, with a 257-load control net and substantial routing delay. The next
revision needs to improve that interface's control fanout/placement or pipeline
structure and repeat routed validation. Do not weaken timing constraints to
accept this artifact. The generated tar is not evidence of timing closure.
No v14 AFI was submitted or loaded; physical speedup remains unmeasured.
v13 completed both full-model requests; see `F2_V13_TESTING.md`.

## Implemented

- Four concurrent attention query lanes, each preserving the original FP32
  accumulation order. A bounded query tile supports incomplete final batches.
- Shared read arbitration combines identical simultaneous Q/K/V/mask requests.
  Requests remain stable under backpressure; each accepted response is delivered
  only to its requesting lanes. Faults and watchdogs stop the whole tile.
- Per-lane block-RAM output buffers allow lanes to compute independently while
  preserving the external sequential output-index/last contract during drain.
- One 64-byte read buffer in the HBM element adapter. Adjacent reads reuse a
  fetched beat. Every accepted write invalidates the buffer; the tensor port
  invalidates it whenever graph execution is inactive, covering host uploads
  and repeated runs. Other bus masters must not mutate tensors during execution.

## Evidence

The serial and four-lane implementations produce identical bits for 7,668
outputs across 30 attention commands, including non-divisible query counts,
causal offsets, masks, dimensions up to 256 and stalls. The independent
binary64 reference comparison has maximum absolute error 6.61029001e-7.
With a fixed 64-cycle memory response delay, aggregate speedup for cases with
at least four queries is **1.537x in simulation**. This is an attention-only
microbenchmark; it excludes the benefit of the separate HBM read buffer and
must not be presented as full-model or physical FPGA speedup.

The read-buffer test requires sixteen adjacent FP32 reads to issue exactly one
AXI read. Tests also cover write invalidation, external-write invalidation,
reset, access bounds, byte strobes, bus faults and response backpressure.
Tensor integration, full integration (49 Python tests), graph-chain/watchdog
regressions and the Vivado host-shell simulation pass.

Standalone head dispatch: setup +0.718 ns, hold +0.042 ns, 19,198 LUTs,
34.5 block-RAM tiles. These estimates do not establish routed timing closure.
See `sim/validation/parallel-v14/` for evidence. Run:

```bash
bash full_model/sim/run_parallel_attention.sh /tmp/openjev-parallel
bash full_model/sim/run_tensor_integration.sh /tmp/openjev-tensor
bash full_model/sim/run_model_integration.sh /tmp/openjev-integration
```

## Remaining performance work

The shared element-request interface still permits one external transaction at
a time. Matrices still operate by rows and gated-delta remains serial. This is
an incremental parallel revision, not a finished low-latency accelerator.
Further work requires tiled K/V storage, pipelined vector arithmetic, parallel
recurrence columns, batched matrix reuse, multiple outstanding HBM bursts and
measured scheduling overlap. Compare each change with the preserved serial
implementation and validate numerical behavior before deployment. No GPU speed,
cost or safety-accuracy claim is supported.

Small single-query commands have additional scheduling/buffering overhead;
the 1.537x aggregate explicitly covers multiquery attention, not every workload.
