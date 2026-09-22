# HBM matrix engine on AWS F2

The AWS `cl_dram_hbm_dma` shell is integrated with the OpenJEV INT8 matrix engine.
The DMA crossbar and HBM calibration/clock crossings are retained. The example's
AXI traffic master is replaced by `cl_dram_dma_axi_mstr.sv`. DDR and debug cores
are disabled. AWS reference RTL and constraints retain their license headers;
see the repository's `AWS_HDK_LICENSE.txt`.

Source baseline: AWS FPGA HDK commit
`b603a81f65666e0cf7a67ee5cf18b148eb6b08c3`. Shell simulation passes on
Vivado 2025.1 and 2025.2. The restored build environment uses 2025.2; see
[the new-instance setup record](validation/NEW_INSTANCE.md).

## Status

Shell simulation passes: both 256-bit halves of 512-bit reads, all 32 banks,
AXI backpressure, repeated commands, result readback, invalid shapes, and AXI
response errors. QKV and vision fixtures match the packed model's SHA256 and
bank contents. The Vivado 2025.2 build closed routed timing after a post-route
repair: setup +0.001 ns, hold +0.007 ns, zero routing errors. AFI
`afi-0c11d6d84c69c667d` / `agfi-0c98e7286f4bae29b` is available and loaded
on the F2. Physical HBM validation passes: both complete weight matrices read
back correctly across all 32 banks, and all outputs match on three runs each.

| Matrix | Shape | Outputs matched per run | Host start-to-done |
|---|---|---|---|
| Layer 0 QKV | 6144 × 1024 | 6144/6144 | 64.0–64.2 ms |
| Vision block 0 FC2 | 768 × 3072 | 768/768 | 26.1–26.2 ms |

Times include activation loading and polling but exclude initial weight upload
and result readback. Raw evidence is in [hardware_results.json](validation/hardware_results.json).
These are matrix correctness tests, not full-model image inference or a GPU
performance comparison.

## Datapath

Host PCIe BAR4 programmed I/O writes weights to HBM. BAR0 writes load the activation vector into BRAM.
The matrix engine reads real HBM via the existing 512-bit AXI crossbar and AWS's
512-to-256-bit HBM adapter. Each 32-byte reader request uses one aligned 64-byte
AXI read; its selected half is forwarded to the compute engine. There is one
outstanding read. Raw signed INT32 results are retained in BRAM for BAR0 readback.
This first integration prioritizes correct physical HBM access; it does not yet
use burst prefetching, all HBM ports in parallel, or a parallel matrix array.

Supported dimensions: 1–8192 rows, 32–4096 columns divisible by 32.
Weight layout: 256-byte chunks striped across 32 banks. Bank-local tensor bases
are 4 KiB aligned. BAR4 address is
`0x1000000000 + bank * 0x20000000 + bank_local_offset`.

## Registers

All engine offsets are relative to BAR0 `0x500`.

| Offset | Meaning |
|---|---|
| `0x00` | Read magic `0x48424d31`; write 1 to start |
| `0x04` | Status: bit 0 busy, bit 1 completed, bit 2 sticky fault, bit 3 activation writable, bit 4 HBM ready |
| `0x08` | Columns, configurable while idle |
| `0x0c` | Rows, configurable while idle |
| `0x10` | Bank-local tensor base, configurable while idle |
| `0x14` | Cycle count from start through completion, including activation loading |
| `0x18` | Accepted 32-byte logical weight requests |
| `0x1c` | Completed output rows |
| `0x20` | Write sequential little-endian 32-bit activation words; poll status bit 3 first |
| `0x24` | Number of accepted activation bytes |
| `0x28` | Write result row index |
| `0x2c` | Read selected signed INT32 raw accumulator |

HBM status remains at absolute BAR0 `0x300`. If not ready, write 1 then 0 and
poll `(status & 0x7) == 0x6`. Bits 2:1 indicate both stacks initialized; bit 0
must be clear. This HDK ties bit 3 to zero despite its legacy MMCM comment.
Never reset HBM during an active transaction.
Matrix-size and allocation-bound calculations are registered to keep them out
of the command-start timing path. The CFG acknowledgement separates successive
configuration writes.

Faults require shell reset/reload. A timeout latches a fault without violating an
outstanding AXI handshake. This prototype does not provide a runtime abort.

## Reproduce

```bash
bash aws_f2/hbm_matvec/sim/run.sh /mnt/fpga-build/hbm-shell-sim
bash aws_f2/build_openjev_hbm.sh
```

The build script copies the canonical engine RTL from `full_model/rtl` and links
AWS's common build scripts. Build on the instance's local NVMe storage and
preserve source/checkpoints/reports on EBS. Do not stop the instance during build.
The current `r6i.xlarge` builder has no local NVMe; it uses its root EBS at
`/home/ubuntu/fpga-build/cl_dram_hbm_dma` through `OPENJEV_CL_DIR`.

For the two residual HBM write-address timing violations in this build, run:

```bash
vivado -mode batch -source aws_f2/hbm_matvec/scripts/repair_route.tcl \
  -tclargs INPUT.post_route.VIOLATED.dcp OUTPUT_PREFIX
```

Review the generated timing, route-status, and DRC reports. The successful
checkpoint is `OUTPUT_PREFIX.dcp`; failure produces a `.VIOLATED.dcp` and an
error. Package the repaired checkpoint with its SHA256 in the AFI manifest.
The AWS packager can package a violated checkpoint, so archive existence alone
is not evidence of timing closure.

After registering and loading the resulting AFI:

```bash
sudo python3 aws_f2/hbm_matvec/host/test_hbm_matvec.py \
  /home/ec2-user/models/hbm \
  /home/ec2-user/models/matvec-qkv /home/ec2-user/models/matvec-vision
```

The test refuses an incorrect design magic, checks HBM calibration, uploads and
reads back both matrices across all 32 banks, and compares every output against
the INT64 software reference on three consecutive runs. `hardware_results.json`
contains counts, hashes, cycle counts, and host elapsed times. Inputs are
synthetic signed INT8 vectors; weights are from the actual checkpoint. These are
raw sums without scales, bias, nonlinearities, or full-model scheduling.

An XDMA driver was built but is not used: the installed HDK explicitly rejects
XDMA-shell AFIs. The supported small shell exposes PCIS through BAR4. This test
uses `fpga_pci_write_burst` and `fpga_pci_peek64`; it makes no DMA-throughput claim.

Unused DMA driver source: AMD `dma_ip_drivers` commit
`b8466090b4e812e191da9e9305ffb11cb7ace768`, with the AWS
`PCI_DEVICE(0x1D0F, 0xF001)` entry added as instructed by the HDK.
