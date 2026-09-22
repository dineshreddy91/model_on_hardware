"""Validate an entire graph before allowing any writes to a hardware backend."""
import hashlib
import json
from abc import ABC, abstractmethod
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field

from ir import GraphProgram
from schema import Opcode


class HardwareCapabilities(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")
    abi: str
    opcodes: frozenset[Opcode]
    max_instructions: int = Field(gt=0)
    max_tensors: int = Field(gt=0)
    model_revision: str
    manifest_sha256: str


class GraphHardware(ABC):
    """Implement with FPGA I/O only; completion includes committed HBM writes."""

    @abstractmethod
    def capabilities(self) -> HardwareCapabilities:
        raise NotImplementedError

    @abstractmethod
    def upload(self, instructions: bytes, tensors: bytes) -> None:
        raise NotImplementedError

    @abstractmethod
    def start(self, instruction_count: int, tensor_count: int) -> None:
        raise NotImplementedError


class ProgramLoader:
    def __init__(self, directory: Path):
        self.directory = directory

    def validate(self, capabilities: HardwareCapabilities) -> GraphProgram:
        requirements = json.loads((self.directory / "requirements.json").read_text())
        for name, key in [("program.bin", "program_sha256"), ("tensors.bin", "tensor_table_sha256"),
                          ("program.json", "graph_json_sha256")]:
            if hashlib.sha256((self.directory / name).read_bytes()).hexdigest() != requirements[key]:
                raise ValueError(f"Artifact checksum mismatch: {name}")
        graph = GraphProgram.model_validate_json((self.directory / "program.json").read_bytes())
        graph.validate_dataflow()
        if graph.format != "openjev-tensor-program-v1" or capabilities.abi != graph.format:
            raise ValueError("Unsupported graph ABI")
        if graph.model_revision != capabilities.model_revision or graph.manifest_sha256 != capabilities.manifest_sha256:
            raise ValueError("Hardware weight identity mismatch")
        if len(graph.instructions) > capabilities.max_instructions or len(graph.tensors) > capabilities.max_tensors:
            raise ValueError("Program exceeds hardware table capacity")
        missing = graph.required_opcodes - capabilities.opcodes
        if missing:
            raise ValueError("Missing FPGA operators: " + ", ".join(op.name for op in sorted(missing)))
        if (self.directory / "program.bin").read_bytes() != b"".join(op.encode() for op in graph.instructions):
            raise ValueError("Instruction binary disagrees with graph")
        if (self.directory / "tensors.bin").read_bytes() != b"".join(t.encode() for t in graph.tensors):
            raise ValueError("Tensor binary disagrees with graph")
        return graph

    def load(self, hardware: GraphHardware) -> GraphProgram:
        graph = self.validate(hardware.capabilities())
        hardware.upload(b"".join(op.encode() for op in graph.instructions),
                        b"".join(t.encode() for t in graph.tensors))
        return graph
