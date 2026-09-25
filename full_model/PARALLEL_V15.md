# v15 parallel matrix and HBM timing revision

Status: functional regressions pass and a separate full-shell build is running
on the existing builder. Routed timing and physical FPGA performance are not
yet established. The v14 full-model simulations remain running with their
original binary and source; these v15 changes do not alter those runs.

## Parallel matrix execution

`openjev_matrix_rows` now schedules tiles of two activation rows. Each lane
contains its own 32-wide INT8 dot-product engine and activation storage. Both
lanes consume one shared weight stream, so each fetched weight vector is used
for two independent outputs. INT32 arithmetic and each dot product's reduction
order are unchanged. An odd final tile enables only one lane.

A locked arbiter serves activation reads and result writes through the existing
tensor port. Output writes may interleave between batch rows; tensor element
indices preserve the original layout. Graph completion waits for both lanes'
committed writes. Weight requests are issued only when all enabled lanes request
the same bank/address; one response is delivered when all enabled lanes can
accept it. Any lane fault stops the wrapper; reset recovery and the whole-command
watchdog remain in place. The serial engine remains available as
`openjev_matrix_rows_lane` for matched comparisons.

## Measured simulation results

Both implementations pass 10857 exact INT32 output checks each, including
partial tiles, 4096-wide inputs, 6144 output rows, striped weights, bus stalls,
input/weight faults, sticky-fault containment and reset recovery.

| Batches × output rows × columns | Serial cycles | Two-lane cycles | Speedup | Weight reads before → after |
| --- | ---: | ---: | ---: | ---: |
| 4 × 1024 × 1024 | 1347834 | 712738 | 1.891x | 131072 → 65536 |
| 4 × 128 × 256 | 50281 | 32293 | 1.557x | 4096 → 2048 |
| 5 × 7 × 4096 | 230153 | 211590 | 1.088x | 4480 → 2688 |
| 1 × 6144 × 32 | 83247 | 83250 | ~1.000x | 6144 → 6144 |

These fixtures use identical deterministic behavioral memory stalls. Activation
loads and result writes remain serialized; activation-heavy cases improve less.
The figures are not whole-model, real-HBM, GPU-comparison or physical-FPGA claims.
The four attention query lanes from v14 are retained; recurrence remains serial.

## HBM write timing change

v14 failed a 450 MHz WREADY-to-wide-payload-enable path. A two-entry circular
FIFO now separates that signal from the existing register slice. Downstream
READY updates only the FIFO read pointer/count; stored payload registers change
only on upstream acceptance. The FIFO carries all 256 data bits, 32 strobes and
LAST. AW and B retain their existing interfaces and ordering. AXI permits
independent AW/W channels, and graph completion still waits for B responses.

FIFO tests cover output stability under stalls, ordering, payload/strobes/LAST,
full backpressure, simultaneous enqueue/dequeue, draining, and reset recovery.
This is a proposed timing fix; only routed validation can establish closure.
No clocks or timing constraints were relaxed.

## Validation and build

- Matrix/FIFO regression: pass; reproduce with
  `bash full_model/sim/run_parallel_matrix.sh /tmp/openjev-v15-matrix`.
- Integrated model-core graph: pass, numerical outputs unchanged.
- Tensor integration regression: pass.
- Host/compiler/reference tests: 57 pass.
- Vivado host-shell simulation: pass with committed numerical outputs. This
  shell smoke does not simulate the physical HBM IP; FIFO behavior is covered
  separately and full synthesis/place/route checks the integration.
- Evidence: [`sim/validation/parallel-v15/`](sim/validation/parallel-v15/).

Builder source: `/home/ubuntu/openjev-model-integration-v15`.
Build: `/home/ubuntu/openjev-full-shell-v15/cl_dram_hbm_dma`.
Log: `/home/ubuntu/openjev-full-shell-v15-build.txt`.
Recipes remain A1/B2/C0/H2 (250 MHz main, 450 MHz HBM).

Before AFI creation, require nonnegative setup and hold slack, complete routing,
zero DRC errors and passing bus-skew checks. Never deploy a VIOLATED checkpoint.
Then run repeated synthetic hardware tests before the same full-model images,
weights and graph used for v13. Keep setup, per-request cycles, transfers and
numerical comparison separate in the result. The earlier provisional CPU
reference limitations remain unresolved.

The last F2 endpoint `ec2-user@ec2-44-204-90-121.compute-1.amazonaws.com` timed out
on September 25. That is an access blocker, not evidence the instance terminated.
A current accessible F2 endpoint is needed for the hardware test. No replacement
instance has been provisioned.
