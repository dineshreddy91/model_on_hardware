# Complete 0.8B model RTL simulation

Status: **both full-model runs started; no completed model prediction yet**.
The existing Ubuntu builder runs the actual v14 RTL compiled with Verilator
5.020. The test includes the entire quantized OpenJEV program (1291 instructions,
2458 tensor descriptors), 32 weight banks (923140096 bytes), and prepared real
Box Runner / Doom inputs. Model revision is
`f004f37e52695d6ddfb914a64dbf93942839ba1e`.

The C++ harness does no learned-model arithmetic. It loads validated program,
metadata, descriptors, weights and input bytes, drives clock/reset/configuration,
services the core's AXI memory bus, and saves final output bytes only after
committed graph completion. It preserves the RTL's default capacity and executes
every clock cycle. It does not substitute CPU implementations for operators.

Memory is a 16 GiB virtual anonymous mapping representing 32 x 512 MiB banks;
only touched pages consume physical RAM. Initial RSS is about 0.9 GiB per run.
AXI reads have a configured 16-cycle delay; the model is single-outstanding and
not a vendor HBM controller performance model. Simulation is two-state functional
RTL, not a gate-level simulation with routed delays. No waveform dump is enabled.

## Validation and current runtime

The compiled harness passed the seven-operation core fixture with the same
logits/probabilities as Icarus and the independent fixture equations. At 16-cycle
reads it completed in 119164 simulated cycles. Differences from the earlier
Icarus cycle count are expected: that bench adds deterministic AW/W/AR stalls.
The full model's bank hashes, program hashes/encoding, kernel metadata and all
11 inputs per image pass validation before execution.

Initial complete-model throughput is approximately 630000 cycles/second per
process. v13 hardware used approximately 675 billion cycles per image, which
would take about 12.4 days at that simulator rate. This is a scale estimate,
**not a prediction of v14's cycle count or completion date**. v14 may reduce the
required cycles. The full simulation remains incomplete and no speed claim is
supported. The runner stops on RTL fault or a one-trillion-cycle budget.

Two independent processes run on the existing builder:

- Box Runner PID 82764, `/home/ubuntu/openjev-full-rtl-v14/box_runner/`.
- Doom PID 82765, `/home/ubuntu/openjev-full-rtl-v14/doom/`.

Each directory contains `run.log`, `provenance.json`, `simulator.txt`, and on
exit `status.json`. Successful completion creates `outputs.bin`. There is no
restart checkpoint: a terminated simulator must restart the graph. Keep the
builder running. A paused/stopped CPU process is not a model completion.

## Reproduce

With Verilator and a C++17 compiler installed:

```bash
bash full_model/sim/verilator/build.sh /tmp/openjev-verilated
export PYTHONPATH=.:full_model/program
python full_model/program/prepare_rtl_simulation.py prepare PROGRAM_DIR HBM_DIR INPUT_DIR OUTPUT_DIR
/tmp/openjev-verilated/Vopenjev_model_core OUTPUT_DIR/simulator.txt 1000000000000 16
python full_model/program/prepare_rtl_simulation.py compare OUTPUT_DIR INPUT_DIR REFERENCE_JSON
```

The input directory must contain the saved `inputs.json` plus binary tensors.
The HBM directory must contain `hbm_manifest.json` and all 32 bank images.
Paths in the simulator configuration must not contain whitespace. Compile
artifacts and large weight files are deliberately outside the repository.

For the harness smoke test:

```bash
python full_model/program/prepare_rtl_simulation.py smoke /tmp/openjev-rtl-smoke
/tmp/openjev-verilated/Vopenjev_model_core /tmp/openjev-rtl-smoke/simulator.txt 5000000 16
python full_model/program/prepare_rtl_simulation.py check_smoke /tmp/openjev-rtl-smoke
```

## Completion criteria and limitations

Require `complete=true`, `fault=0`, 1290 retired instructions (plus END), all
output bytes, and no pending AXI transaction. The comparison command refuses
incomplete runs and verifies model/input identity against the stored offline
CPU reference before reporting numerical differences. The reference remains
provisional; matching its top class is not a correctness acceptance criterion.
See `BASELINE_AUDIT.md` for unresolved baseline differences.

The physical v14 checkpoint failed setup timing. Even complete successful RTL
simulation cannot establish physical F2 latency, timing closure, GPU advantage,
or suitability for safety decisions. Hardware cycle count and simulator wall
time will be reported separately. Provenance and smoke evidence are under
`sim/validation/full-rtl-v14/`; full-model result files will be added only after
actual completion.
