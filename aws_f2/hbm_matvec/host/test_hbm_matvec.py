"""Hardware-only HBM validation; refuses to run against another FPGA design.

Usage: sudo python3 test_hbm_matvec.py HBM_DIRECTORY FIXTURE_DIRECTORY [...]
Fixtures contain real checkpoint weights and deterministic synthetic activations.
No CPU inference fallback is implemented.
"""
import ctypes as C
import hashlib
import json
import struct
import sys
import time
from contextlib import ExitStack
from pathlib import Path


class F2Device:
    IMAGE_ID = 0x48424D31
    REJECT_STATUS_MASK = 5

    def __init__(self, slot: int = 0):
        self.slot = slot
        self.lib = C.CDLL("libfpga_mgmt.so")
        signatures = {
            "fpga_mgmt_init": [],
            "fpga_pci_attach": [C.c_int, C.c_int, C.c_int, C.c_uint32, C.POINTER(C.c_int)],
            "fpga_pci_detach": [C.c_int],
            "fpga_pci_poke": [C.c_int, C.c_uint64, C.c_uint32],
            "fpga_pci_peek": [C.c_int, C.c_uint64, C.POINTER(C.c_uint32)],
            "fpga_pci_write_burst": [C.c_int, C.c_uint64, C.POINTER(C.c_uint32), C.c_uint64],
            "fpga_pci_peek64": [C.c_int, C.c_uint64, C.POINTER(C.c_uint64)],
        }
        for name, args in signatures.items():
            function = getattr(self.lib, name)
            function.argtypes = args
            function.restype = C.c_int
        self.handle = C.c_int(-1)
        self.memory_handle = C.c_int(-1)
        self.resources = ExitStack()

    @staticmethod
    def check(code: int, operation: str) -> None:
        if code != 0:
            raise RuntimeError(f"{operation} failed: {code}")

    def __enter__(self):
        try:
            self.check(self.lib.fpga_mgmt_init(), "management init")
            self.check(self.lib.fpga_pci_attach(self.slot, 0, 0, 0, C.byref(self.handle)), "BAR0 attach")
            self.resources.callback(self.lib.fpga_pci_detach, self.handle)
            if self.read(0x500) != self.IMAGE_ID:
                raise RuntimeError(f"Loaded AFI has the wrong design identity; expected {self.IMAGE_ID:#x}")
            if self.read(0x504) & self.REJECT_STATUS_MASK:
                raise RuntimeError("Engine is busy or faulted; reload AFI before testing")
            self.check(self.lib.fpga_pci_attach(self.slot, 0, 4, 0, C.byref(self.memory_handle)), "BAR4 attach")
            self.resources.callback(self.lib.fpga_pci_detach, self.memory_handle)
            return self
        except BaseException:
            self.resources.close()
            raise

    def __exit__(self, *exc):
        self.resources.close()

    def read(self, address: int) -> int:
        value = C.c_uint32()
        self.check(self.lib.fpga_pci_peek(self.handle, address, C.byref(value)), "BAR read")
        return value.value

    def write(self, address: int, value: int) -> None:
        self.check(self.lib.fpga_pci_poke(self.handle, address, value), "BAR write")

    def initialize_hbm(self) -> None:
        # This HDK drives bit 3 to zero; bits 2:1 indicate both stacks ready.
        # Bit 0 must also be clear so calibration isn't accepted during reset.
        if self.read(0x300) & 0x7 != 0x6:
            self.write(0x300, 1)
            time.sleep(0.01)
            self.write(0x300, 0)
        deadline = time.monotonic() + 30
        while self.read(0x300) & 0x7 != 0x6:
            if time.monotonic() > deadline:
                raise TimeoutError("HBM failed calibration")
            time.sleep(0.01)
        if not self.read(0x504) & 16:
            raise RuntimeError("HBM calibration and engine readiness disagree")
        print("HBM calibration PASS", flush=True)

    def upload(self, address: int, payload: bytes) -> None:
        words = (C.c_uint32 * (len(payload)//4)).from_buffer_copy(payload)
        self.check(self.lib.fpga_pci_write_burst(self.memory_handle, address, words, len(words)), "BAR4 write")

    def verify(self, address: int, payload: bytes) -> None:
        value = C.c_uint64()
        for offset, (expected,) in enumerate(struct.iter_unpack("<Q", payload)):
            self.check(self.lib.fpga_pci_peek64(self.memory_handle, address+offset*8, C.byref(value)), "BAR4 read")
            if value.value != expected:
                raise RuntimeError(f"HBM readback differs at {address+offset*8:#x}: got {value.value:#x}, expected {expected:#x}")

    def run(self, columns: int, rows: int, base: int, activations: bytes) -> dict:
        if len(activations) != columns:
            raise ValueError("Activation size mismatch")
        if self.read(0x504) & 5:
            raise RuntimeError("Engine busy or faulted")
        self.write(0x508, columns)
        self.write(0x50C, rows)
        self.write(0x510, base)
        started = time.monotonic()
        self.write(0x500, 1)
        for (word,) in struct.iter_unpack("<I", activations):
            while True:
                status = self.read(0x504)
                if status & 4:
                    raise RuntimeError(f"Engine fault while loading activations: {status:#x}")
                if status & 8:
                    break
                if time.monotonic() - started > 15:
                    raise TimeoutError("Activation load timed out")
            self.write(0x520, word)
        while True:
            status = self.read(0x504)
            if status & 4:
                raise RuntimeError(f"Engine fault: {status:#x}")
            if status & 2:
                break
            if time.monotonic() - started > 15:
                raise TimeoutError("Matrix hardware execution timed out")
            time.sleep(0.001)
        completed = time.monotonic()
        if status & 1 or self.read(0x51C) != rows or self.read(0x518) != columns * rows // 32:
            raise RuntimeError("Invalid completion counts")
        if self.read(0x524) != columns:
            raise RuntimeError("Invalid activation count")
        output = []
        for row in range(rows):
            self.write(0x528, row)
            output.append(C.c_int32(self.read(0x52C)).value)
        return {"output": output, "cycles_including_activation_load": self.read(0x514),
                "transport": "PCIe BAR4 programmed I/O", "requests": self.read(0x518), "host_start_to_done_seconds": completed-started,
                "host_start_to_readback_seconds": time.monotonic()-started}


class Fixture:
    def __init__(self, hbm: Path, fixture: Path):
        self.directory = fixture
        self.metadata = json.loads((fixture / "metadata.json").read_text())
        manifest = json.loads((hbm / "hbm_manifest.json").read_text())
        if (manifest["bank_count"], manifest["burst_bytes"]) != (32, 256):
            raise ValueError("Unsupported HBM stripe format")
        self.entry = next(x for x in manifest["tensors"] if x["name"] == self.metadata["tensor"])
        self.rows, self.columns = self.metadata["rows"], self.metadata["columns"]
        self.base = self.entry["base_address"]
        if not (0 < self.rows <= 8192 and 0 < self.columns <= 4096 and self.columns % 32 == 0):
            raise ValueError("Unsupported matrix shape")
        self.weights = self.read_mem(fixture / "weights.mem")
        self.activations = self.read_mem(fixture / "activations.mem")
        self.expected = [C.c_int32(int(x, 16)).value for x in (fixture / "expected.mem").read_text().split()]
        if (len(self.weights) != self.rows*self.columns or len(self.activations) != self.columns
                or len(self.expected) != self.rows or hashlib.sha256(self.weights).hexdigest() != self.entry["sha256"]):
            raise ValueError("Fixture shape/checksum mismatch")
        allocation = ((len(self.weights)+8191)//8192)*256
        if self.base % 4096 or self.base < 0 or self.base + allocation > 0x20000000:
            raise ValueError("HBM allocation out of bounds")
        self.banks = [bytearray(allocation) for _ in range(32)]
        for chunk, offset in enumerate(range(0, len(self.weights), 256)):
            block = self.weights[offset:offset+256]
            local_offset = (chunk//32)*256
            self.banks[chunk%32][local_offset:local_offset+len(block)] = block
        # Verify the data we will send against the existing packed model images.
        for bank, payload in enumerate(self.banks):
            with (hbm / f"hbm_bank_{bank:02d}.bin").open("rb") as stream:
                stream.seek(self.base)
                existing = stream.read(allocation)
            # Both selected test matrices fill complete 8192-byte stripes.
            if len(self.weights) % 8192 or existing != payload:
                raise ValueError("Fixture differs from packed HBM model")

    @staticmethod
    def read_mem(path: Path) -> bytes:
        return b"".join(bytes.fromhex(line)[::-1] for line in path.read_text().split())

    def execute(self, device: F2Device) -> list[dict]:
        started = time.monotonic()
        for bank, payload in enumerate(self.banks):
            device.upload(0x1000000000 + bank*0x20000000 + self.base, bytes(payload))
        # Read every bank only after all writes, so bank-address aliasing is detectable.
        for bank, payload in enumerate(self.banks):
            device.verify(0x1000000000 + bank*0x20000000 + self.base, bytes(payload))
        upload_seconds = time.monotonic()-started
        print(f"PCIe BAR4/HBM readback PASS: {self.metadata['tensor']} ({len(self.weights)} bytes)", flush=True)
        reports = []
        for run in range(3):
            result = device.run(self.columns, self.rows, self.base, self.activations)
            output = result.pop("output")
            if output != self.expected:
                mismatches = [(i,a,b) for i,(a,b) in enumerate(zip(output,self.expected)) if a != b]
                raise RuntimeError(f"Hardware mismatch: {len(mismatches)} rows; first {mismatches[:5]}")
            result.update(tensor=self.metadata["tensor"], rows=self.rows, columns=self.columns,
                          run=run, matched_outputs=len(output), upload_and_verify_seconds=upload_seconds,
                          output_sha256=hashlib.sha256(struct.pack(f"<{len(output)}i", *output)).hexdigest())
            print("PASS " + json.dumps(result), flush=True)
            reports.append(result)
        return reports


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    fixtures = [Fixture(Path(sys.argv[1]), Path(x)) for x in sys.argv[2:]]
    with F2Device() as device:
        device.initialize_hbm()
        results = [report for fixture in fixtures for report in fixture.execute(device)]
    Path("hardware_results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
