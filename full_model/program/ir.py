"""Program validation, fixed-width binaries and striped-HBM lifetime allocation."""
import hashlib
import json
from pathlib import Path

from pydantic import BaseModel, ConfigDict

from schema import InputProfile, Instruction, Opcode, Storage, Tensor


class GraphProgram(BaseModel):
    model_config = ConfigDict(extra="forbid")
    format: str = "openjev-tensor-program-v1"
    model_revision: str = "f004f37e52695d6ddfb914a64dbf93942839ba1e"
    profile: InputProfile
    tensors: list[Tensor]
    instructions: list[Instruction]
    outputs: tuple[int, ...]
    covered_weights: tuple[str, ...]
    input_ids: tuple[int, ...]
    peak_bank_address: int
    config_sha256: str
    manifest_sha256: str

    @property
    def required_opcodes(self) -> set[Opcode]:
        return {op.opcode for op in self.instructions if op.opcode != Opcode.END}

    def validate_dataflow(self) -> None:
        if [t.id for t in self.tensors] != list(range(len(self.tensors))):
            raise ValueError("Tensor IDs must be dense and ordered")
        if self.format != "openjev-tensor-program-v1":
            raise ValueError("Unsupported graph format")
        if not 1 <= len(self.instructions) <= 4096:
            raise ValueError("Invalid program length")
        if set(self.input_ids) != {t.id for t in self.tensors if t.storage == Storage.INPUT}:
            raise ValueError("Input table mismatch")
        initialized = {t.id for t in self.tensors if t.storage in (Storage.INPUT, Storage.WEIGHT)}
        written = set()
        for index, instruction in enumerate(self.instructions):
            if instruction.tag != index:
                raise ValueError("Instruction tags must equal program counters")
            if instruction.opcode == Opcode.END:
                if index != len(self.instructions) - 1:
                    raise ValueError("Premature END")
                continue
            for tid in instruction.sources:
                if tid >= len(self.tensors) or self.tensors[tid].root not in initialized:
                    raise ValueError(f"Read before definition in {instruction.stage}: tensor {tid}")
            for tid in instruction.destinations:
                if tid >= len(self.tensors):
                    raise ValueError("Invalid destination ID")
                tensor = self.tensors[tid]
                if tensor.storage != Storage.SCRATCH or tensor.id != tensor.root or tid in written:
                    raise ValueError("Instructions must define a fresh scratch root")
                initialized.add(tid)
                written.add(tid)
        if not self.instructions or self.instructions[-1].opcode != Opcode.END:
            raise ValueError("Program needs exactly one final END")
        for tensor in self.tensors:
            if tensor.root >= len(self.tensors):
                raise ValueError("Unknown view root")
            root = self.tensors[tensor.root]
            if root.storage == Storage.VIEW or tensor.dtype != root.dtype or tensor.span > root.logical_bytes:
                raise ValueError(f"Invalid tensor view: {tensor.name}")
            required_extent = ((root.logical_bytes + 8191) // 8192) * 256
            if root.extent < required_extent or (root.storage != Storage.VIEW and root.offset):
                raise ValueError("Root allocation is smaller than its tensor")
            if root.storage == Storage.WEIGHT and root.base + root.extent > 0x02000000:
                raise ValueError("Weight allocation exceeds protected region")
            if tensor.base != root.base or root.base + root.extent > 0x20000000:
                raise ValueError("Invalid physical placement")
            if tensor.storage != Storage.WEIGHT and root.storage != Storage.WEIGHT and root.base < 0x02000000:
                raise ValueError("Activation placement overlaps protected weights")
        # Check physical overlap independently of the allocation algorithm.
        births = {t.id: -1 for t in self.tensors if t.storage in (Storage.INPUT, Storage.WEIGHT)}
        ends = {tid: len(self.instructions) for tid in births}
        for index, instruction in enumerate(self.instructions):
            for tid in instruction.destinations:
                births[tid] = index
                ends[tid] = index
            for tid in instruction.sources:
                root_id = self.tensors[tid].root
                ends[root_id] = max(ends.get(root_id, index), index)
        for tid in self.outputs:
            if tid >= len(self.tensors):
                raise ValueError("Unknown output")
            ends[self.tensors[tid].root] = len(self.instructions)
        live = []
        for tid in sorted(births, key=births.get):
            first = births[tid]
            live = [other for other in live if ends[other] >= first]
            tensor = self.tensors[tid]
            for other in live:
                peer = self.tensors[other]
                if tensor.base < peer.base + peer.extent and peer.base < tensor.base + tensor.extent:
                    raise ValueError(f"Overlapping live allocations: {tensor.name}, {peer.name}")
            live.append(tid)
        if any(tid not in initialized for tid in self.outputs):
            raise ValueError("Output not defined")

    def write(self, destination: Path) -> None:
        self.validate_dataflow()
        destination.mkdir(parents=True, exist_ok=True)
        program = b"".join(instruction.encode() for instruction in self.instructions)
        tensor_table = b"".join(tensor.encode() for tensor in self.tensors)
        (destination / "program.bin").write_bytes(program)
        (destination / "program.mem").write_text("".join(program[i:i + 64][::-1].hex() + "\n" for i in range(0, len(program), 64)))
        (destination / "tensors.bin").write_bytes(tensor_table)
        (destination / "program.json").write_text(self.model_dump_json(indent=2) + "\n")
        (destination / "requirements.json").write_text(json.dumps({
            "format": self.format, "instructions": len(self.instructions), "tensors": len(self.tensors),
            "instruction_bytes": 64, "tensor_descriptor_bytes": 128,
            "required_opcodes": {str(int(op)): op.name for op in sorted(self.required_opcodes)},
            "program_sha256": hashlib.sha256(program).hexdigest(),
            "tensor_table_sha256": hashlib.sha256(tensor_table).hexdigest(),
            "graph_json_sha256": hashlib.sha256((destination / "program.json").read_bytes()).hexdigest(),
            "deployed_full_model": False,
            "precision": "dynamic row INT8 activations; per-output INT8/FP16 weights; FP32 tensor operations",
        }, indent=2) + "\n")


class LifetimeAllocator:
    @staticmethod
    def align(value: int) -> int:
        return (value + 4095) & -4096

    def place(self, tensors: list[Tensor], instructions: list[Instruction], outputs: tuple[int, ...]) -> tuple[list[Tensor], int]:
        births, ends = {}, {}
        for index, instruction in enumerate(instructions):
            for tid in instruction.destinations:
                births[tid] = index
                ends[tid] = index
            for tid in instruction.sources:
                root = tensors[tid].root
                ends[root] = max(ends.get(root, 0), index)
        for tid in outputs:
            ends[tid] = len(instructions)
        bases = {t.id: t.base for t in tensors if t.storage == Storage.WEIGHT}
        extents = {t.id: t.extent for t in tensors if t.storage == Storage.WEIGHT}
        next_base = 0x02000000
        active: list[tuple[int, int, int]] = []
        free: list[tuple[int, int]] = []
        for tensor in tensors:
            if tensor.storage == Storage.INPUT:
                size = self.align(((tensor.logical_bytes + 8191) // 8192) * 256)
                bases[tensor.id], extents[tensor.id] = next_base, size
                next_base += size
        for tid in sorted(births, key=births.get):
            first = births[tid]
            still_active = []
            for last, base, size in active:
                if last < first:
                    free.append((base, size))
                else:
                    still_active.append((last, base, size))
            active = still_active
            free.sort()
            merged = []
            for base, size in free:
                if merged and merged[-1][0] + merged[-1][1] == base:
                    merged[-1] = (merged[-1][0], merged[-1][1] + size)
                else:
                    merged.append((base, size))
            free = merged
            size = self.align(((tensors[tid].logical_bytes + 8191) // 8192) * 256)
            available = [(length, index) for index, (_, length) in enumerate(free) if length >= size]
            if available:
                _, selected = min(available)
                base, length = free.pop(selected)
                if length > size:
                    free.append((base + size, length - size))
            else:
                base = next_base
                next_base += size
            if next_base > 0x20000000:
                raise ValueError("Graph exceeds per-bank HBM capacity")
            bases[tid], extents[tid] = base, size
            active.append((ends[tid], base, size))
        return [t.model_copy(update={"base": bases[t.root], "extent": extents[t.root]}) for t in tensors], next_base
