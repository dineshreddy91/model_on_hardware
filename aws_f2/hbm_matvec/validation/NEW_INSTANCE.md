# New F2 bring-up — 2026-09-21 Pacific time

Instance: `i-0bb375888c477ede7` (`f2.6xlarge`, us-east-1d).
SSH: `ec2-user@ec2-35-175-208-193.compute-1.amazonaws.com`.
The AMI rejects direct root login; use `sudo` after connecting.

Completed:

- Attached existing `ModelOnHardwareFpgaProfile` with user approval; verified
  `sts get-caller-identity` returns its assumed role.
- Restored project sources to `/home/ec2-user/model_on_hardware` on EBS.
- Cloned AWS FPGA SDK/HDK to `/home/ec2-user/aws-fpga` and pinned
  `b603a81f65666e0cf7a67ee5cf18b148eb6b08c3`.
- Installed SDK management tools, shared library, Python development headers,
  and Cython bindings successfully.
- Verified the 875.4 GiB NVMe instance-storage device had no filesystem signatures,
  formatted it as ext4, and mounted it at `/mnt/fpga-build`.
- Linked `/mnt/fpga-build/aws-fpga` to the EBS-backed SDK checkout.
- Loaded existing classifier `agfi-0d2a6c428a2d5bdfb` into slot 0.
- Compiled and ran `test_openjev_head` three times on physical hardware. All nine
  accumulators matched: 26198, 35544, -38063 on each run.
- Four HBM fixture-integrity tests pass on the new operating system.

The running AMI is **Deep Learning AMI Neuron (Amazon Linux 2023) 20260115**;
it does not contain Vivado. The existing stopped FPGA Developer instance
`i-0d924d0c09281d49e` was started with explicit user approval. It has Vivado 2025.2, which this HDK
revision supports. SSH uses `ubuntu@ec2-18-234-238-25.compute-1.amazonaws.com`.
The project is at `/home/ubuntu/model_on_hardware`; the active build is at
`/home/ubuntu/fpga-build/cl_dram_hbm_dma`, with its log at
`/home/ubuntu/hbm-build-setup.log`. Shell simulation passes on Vivado 2025.2.
The completed HBM build and hardware results are recorded below.

No project source was uploaded to S3; the user chose EBS and local copies.
The source archive on the F2 is `/home/ec2-user/model_on_hardware_restore.tar.gz`.
Instance storage is scratch space and must not be the only copy of build inputs
or completed checkpoints. The NVMe mount above is currently a manual mount.

The previous S3 bucket contains the classifier DCP and AFI reports only; no HBM
DCP was present when checked. The original model was downloaded at Hugging Face revision
`f004f37e52695d6ddfb914a64dbf93942839ba1e`. All 732 quantized tensors were
reconstructed on the new F2 with exact saved SHA256/shape/dtype matches, using
`full_model/tools/restore_quantized_checkpoint.py`. The restored checkpoint is
`/home/ec2-user/models/openjev-0.8b-int8.safetensors`.

The full 923,140,096-byte HBM image has been rebuilt at
`/home/ec2-user/models/hbm`; all 32 bank SHA256 hashes match the saved manifest.
Real QKV and vision fixtures are at `/home/ec2-user/models/matvec-qkv` and
`/home/ec2-user/models/matvec-vision`. The new Vivado 2025.2 build completed
synthesis without errors. Initial post-optimization setup timing was
+0.504 ns on `clk_main_a0` and +0.657 ns on the HBM AXI clock. These figures
are pre-placement estimates, not final timing closure.

The first routed build completed in 56m59s, with two HBM write-address setup
violations: -0.005 ns and -0.004 ns. Hold slack was +0.008 ns. The initial
checkpoint is marked `post_route.VIOLATED.dcp` and has not been submitted for
AFI creation. Its report is `post-route-before-repair-2025.2.rpt`. A post-route
physical optimization attempt was run from that checkpoint, using
`scripts/repair_route.tcl`; clocks and timing exceptions are unchanged.

The repair subsequently passed: WNS +0.001 ns, WHS +0.007 ns, zero setup,
hold, or pulse-width failing endpoints. All 102,804 routable nets are routed,
with zero routing errors. DRC has warnings/advisories but no errors or critical
warnings. The `repaired-*-2025.2.rpt` files preserve these reports.

Repaired DCP SHA256: `cb245b82b204306f11070062fe08ba832d5eaaaa4e198d91013eef34cada0460`.
Compiled AFI archive SHA256: `139f56c018eb41057962157a6da3bb8579b014d2e17442e958e656b5ca1ef4e6`.
Only this compiled checkpoint archive was uploaded to the private build bucket,
at `dcp/openjev-hbm-v2-139f56c018eb4105.Developer_CL.tar`.
AFI creation accepted: `afi-0c11d6d84c69c667d`, global ID
`agfi-0c98e7286f4bae29b`. Availability and hardware results are recorded below.

After repair, the temporary builder was cleanly shut down and EC2 confirmed
`Stopped`. Its shutdown behavior is `Stop`; EBS retains the build tree. Its
previous public address above is no longer valid after stopping. The runtime
F2 remains running. Updated source is archived locally at
`/private/tmp/model_on_hardware_hbm_20260922.tar.gz` and on the F2 at
`/home/ec2-user/model_on_hardware_hbm_20260922.tar.gz`, with no source archive
uploaded to S3.

## Hardware result

AWS subsequently marked the AFI available. It is loaded in F2 slot 0 with
status `ok`, shell `0x10212415`, device `1d0f:f001`.
The first test incorrectly waited for status bit 3, which this HDK ties to zero
despite a legacy comment. Live status was already `0x6`, with engine-ready
`0x10`. The host check now requires `(status & 7) == 6`; six host regression
tests pass locally and on the F2. No hardware rebuild was needed for this fix.

All physical tests then passed:

- QKV: 6,291,456 weight bytes read back, 196,608 logical requests per run,
  all 6,144 outputs exact on each of three runs.
- Vision FC2: 2,359,296 weight bytes read back, 73,728 logical requests per run,
  all 768 outputs exact on each of three runs.
- Every bank was written before verifying all 32 banks, detecting address aliasing.
- Post-test shell timeout, range-error, and AXI-protocol-error counters were zero.

`hardware_results.json` and `hbm-hardware-test.txt` retain raw results. The F2
remains running with the HBM image loaded. These tests use real model weights
and synthetic activation vectors; full image inference is not implemented.
