"""FPGA-only graph runtime. No CPU model computation or fallback is provided."""
import ctypes as C
import math
import struct
import time
from collections.abc import Callable

from aws_f2.hbm_matvec.host.test_hbm_matvec import F2Device


class FullModelDevice(F2Device):
    IMAGE_ID = 0x4F4A4631
    REJECT_STATUS_MASK = 13

    def check_status(self):
        status = self.read(0x504)
        if status & 12:
            raise RuntimeError(f"FPGA fault: status={status:#x}, code={self.read(0x538)}")
        return status

    def load_record(self, index: int, payload: bytes, data_register: int, commit_register: int):
        self.write(0x510, index)
        for word, in struct.iter_unpack("<I", payload):
            self.write(data_register, word)
        self.write(commit_register, 1)
        self.check_status()

    def configure(self, instructions: bytes, descriptors: bytes, metadata: bytes):
        if (not instructions or len(instructions) % 64 or not descriptors or len(descriptors) % 128
                or len(metadata) != len(instructions) // 64 * 32):
            raise ValueError("Incomplete FPGA configuration records")
        instruction_count, tensor_count = len(instructions) // 64, len(descriptors) // 128
        if instruction_count > self.read(0x544) or tensor_count > self.read(0x548):
            raise ValueError("FPGA table capacity exceeded")
        if self.read(0x540) != 1 or self.read(0x53C) & 0xFFFFFE != 0xFFFFFE:
            raise RuntimeError("FPGA ABI or operator capability mismatch")
        if self.check_status() & 1:
            raise RuntimeError("Cannot configure an active graph")
        self.write(0x508, instruction_count)
        self.write(0x50C, tensor_count)
        for index in range(tensor_count):
            self.load_record(index, descriptors[index * 128:(index + 1) * 128], 0x524, 0x528)
        for index in range(instruction_count):
            self.load_record(index, instructions[index * 64:(index + 1) * 64], 0x514, 0x518)
            self.load_record(index, metadata[index * 32:(index + 1) * 32], 0x51C, 0x520)

    @staticmethod
    def address(base: int, offset: int) -> int:
        return 0x1000000000 + ((offset >> 8) % 32) * 0x20000000 + base + (offset >> 13) * 256 + offset % 256

    def upload_input(self, tensor, payload: bytes):
        if tensor.storage.value != "input" or len(payload) != tensor.logical_bytes or tensor.base < 0x02000000:
            raise ValueError("Input payload or protected memory mismatch")
        for offset in range(0, len(payload), 256):
            part = payload[offset:offset + 256]
            self.upload(self.address(tensor.base, offset), part + bytes((-len(part)) % 4))

    def download_output(self, tensor) -> bytes:
        if tensor.root != tensor.id or tensor.dtype.value != "float32":
            raise ValueError("Expected contiguous FP32 output root")
        payload = bytearray()
        value = C.c_uint64()
        for offset in range(0, tensor.logical_bytes, 8):
            self.check(self.lib.fpga_pci_peek64(self.memory_handle, self.address(tensor.base, offset), C.byref(value)), "output read")
            payload.extend(struct.pack("<Q", value.value))
        return bytes(payload[:tensor.logical_bytes])

    def execute(self, graph, input_payloads: dict[int, bytes], timeout_seconds: float = 3600,
                progress: Callable[[dict], None] | None = None) -> dict:
        if set(input_payloads) != set(graph.input_ids):
            raise ValueError("Missing or unexpected graph inputs")
        for tid, payload in input_payloads.items():
            if len(payload) != graph.tensors[tid].logical_bytes:
                raise ValueError("Input byte count mismatch")
        if self.check_status() & 1:
            raise RuntimeError("FPGA is already active")
        start = time.perf_counter_ns()
        for tid, payload in input_payloads.items():
            self.upload_input(graph.tensors[tid], payload)
        uploaded = time.perf_counter_ns()
        self.write(0x500, 1)
        deadline = time.monotonic() + timeout_seconds
        next_progress = time.monotonic() + 20
        while True:
            status = self.check_status()
            if status & 2 and not status & 1:
                break
            if time.monotonic() > deadline:
                raise TimeoutError("Full-model FPGA inference timed out; reset the image before retrying")
            if progress is not None and time.monotonic() >= next_progress:
                retired_now = self.read(0x534)
                progress({"instructions_retired": retired_now,
                          "stage": graph.instructions[min(retired_now, len(graph.instructions) - 1)].stage,
                          "elapsed_device_request_ms": (time.perf_counter_ns() - uploaded) / 1e6})
                next_progress = time.monotonic() + 20
            time.sleep(0.001)
        completed = time.perf_counter_ns()
        retired = self.read(0x534)
        if retired != len(graph.instructions) - 1:
            raise RuntimeError("FPGA reported incomplete graph retirement")
        cycles = self.read(0x52C) | self.read(0x530) << 32
        outputs = {}
        for tid in graph.outputs:
            payload = self.download_output(graph.tensors[tid])
            values = [v for v, in struct.iter_unpack("<f", payload)]
            if not all(math.isfinite(v) for v in values):
                raise RuntimeError("Nonfinite FPGA output")
            outputs[graph.tensors[tid].name] = values
        finished = time.perf_counter_ns()
        return {"execution": "full_model_fpga", "instructions_retired": retired, "device_cycles": cycles,
                "input_transfer_ms": (uploaded - start) / 1e6,
                "start_to_committed_completion_ms": (completed - uploaded) / 1e6,
                "output_transfer_ms": (finished - completed) / 1e6,
                "device_request_wall_ms": (finished - start) / 1e6,
                "outputs": outputs, "cpu_model_fallback": False}
