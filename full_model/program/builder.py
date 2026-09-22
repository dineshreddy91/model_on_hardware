"""Typed tensor registry and lowering helpers shared by vision and text graphs."""
import math
import struct

from pydantic import BaseModel, ConfigDict, Field

from schema import DType, Instruction, Opcode, Storage, Tensor


class WeightPlacement(BaseModel):
    model_config = ConfigDict(extra="ignore")
    name: str
    shape: tuple[int, ...]
    dtype: DType
    base_address: int = Field(ge=0, lt=0x20000000)
    logical_bytes: int = Field(gt=0)
    padded_bytes: int = Field(gt=0)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


class TensorRegistry:
    def __init__(self):
        self.tensors: list[Tensor] = []
        self.names: dict[str, int] = {}

    def add(self, name: str, shape: tuple[int, ...], dtype: DType = DType.FLOAT32,
            storage: Storage = Storage.SCRATCH, base: int = 0, extent: int = 0) -> int:
        if name in self.names:
            raise ValueError(f"Duplicate tensor {name}")
        tid = len(self.tensors)
        tensor = Tensor(id=tid, name=name, shape=shape, dtype=dtype, storage=storage, root=tid,
                        strides=Tensor.contiguous_strides(shape, dtype), base=base, extent=extent)
        self.tensors.append(tensor)
        self.names[name] = tid
        return tid

    def view(self, name: str, source: int, shape: tuple[int, ...], offset: int = 0,
             strides: tuple[int, ...] | None = None) -> int:
        parent = self.tensors[source]
        if strides is None:
            if parent.strides != Tensor.contiguous_strides(parent.shape, parent.dtype):
                raise ValueError("Cannot reshape a noncontiguous view")
            if math.prod(shape) != math.prod(parent.shape):
                raise ValueError("Reshape changes element count")
            strides = Tensor.contiguous_strides(shape, parent.dtype)
        tid = len(self.tensors)
        if name in self.names:
            raise ValueError("Duplicate view name")
        tensor = Tensor(id=tid, name=name, shape=shape, dtype=parent.dtype, storage=Storage.VIEW,
                        root=parent.root, offset=parent.offset + offset, strides=strides)
        if tensor.span > self.tensors[parent.root].logical_bytes:
            raise ValueError("View exceeds root")
        self.tensors.append(tensor)
        self.names[name] = tid
        return tid


class GraphBuilder:
    def __init__(self, weights: list[WeightPlacement]):
        self.registry = TensorRegistry()
        self.instructions: list[Instruction] = []
        self.used_weights: set[str] = set()
        for placement in weights:
            shape = placement.shape
            if len(shape) > 4:
                shape = (shape[0], math.prod(shape[1:]))
            tid = self.registry.add(placement.name, shape, placement.dtype, Storage.WEIGHT,
                                    placement.base_address, placement.padded_bytes // 32)
            if self.registry.tensors[tid].logical_bytes != placement.logical_bytes:
                raise ValueError("Manifest tensor size mismatch")
            if placement.base_address + placement.padded_bytes // 32 > 0x02000000:
                raise ValueError("Weight image exceeds protected region")

    def weight(self, name: str) -> int:
        tid = self.registry.names[name]
        if self.registry.tensors[tid].storage != Storage.WEIGHT:
            raise ValueError("Expected checkpoint weight")
        self.used_weights.add(name)
        return tid

    @staticmethod
    def float_bits(value: float) -> int:
        return struct.unpack("<I", struct.pack("<f", value))[0]

    def emit(self, opcode: Opcode, stage: str, sources: tuple[int, ...], destinations: tuple[int, ...],
             parameters: tuple[int, ...] = (), flags: int = 0) -> None:
        self.instructions.append(Instruction(opcode=opcode, stage=stage, tag=len(self.instructions),
                                             sources=sources, destinations=destinations, parameters=parameters, flags=flags))

    def operation(self, opcode: Opcode, name: str, sources: tuple[int, ...], shape: tuple[int, ...] | None = None,
                  parameters: tuple[int, ...] = (), flags: int = 0) -> int:
        if shape is None:
            shape = self.registry.tensors[sources[0]].shape
        output = self.registry.add(name, shape)
        self.emit(opcode, name, sources, (output,), parameters, flags)
        return output

    def linear(self, source: int, prefix: str, name: str) -> int:
        input_tensor = self.registry.tensors[source]
        weight, scales = self.weight(prefix + ".weight"), self.weight(prefix + ".weight.scale")
        matrix = self.registry.tensors[weight]
        rows, columns = matrix.shape[0], math.prod(matrix.shape[1:])
        if input_tensor.shape[-1] != columns or columns > 4096 or rows > 8192:
            raise ValueError(f"Linear geometry unsupported: {prefix}")
        leading = input_tensor.shape[:-1]
        quantized = self.registry.add(name + ".int8", input_tensor.shape, DType.INT8)
        input_scales = self.registry.add(name + ".input_scales", leading or (1,))
        self.emit(Opcode.QUANTIZE, name + ".quantize", (source,), (quantized, input_scales), (columns,))
        accumulator = self.registry.add(name + ".accumulator", leading + (rows,), DType.INT32)
        self.emit(Opcode.LINEAR_I8, name + ".matrix", (quantized, weight), (accumulator,),
                  (math.prod(leading), rows, columns))
        output = self.operation(Opcode.DEQUANTIZE, name + ".scaled", (accumulator, input_scales, scales))
        if prefix + ".bias" in self.registry.names:
            output = self.operation(Opcode.ADD, name + ".biased", (output, self.weight(prefix + ".bias")), flags=1)
        return output

    def norm(self, source: int, prefix: str, name: str, rms: bool = False, zero_centered: bool = False) -> int:
        gamma = self.weight(prefix + ".weight")
        if self.registry.tensors[source].shape[-1] != self.registry.tensors[gamma].shape[0]:
            raise ValueError("Norm width mismatch")
        sources = (source, gamma) if rms else (source, gamma, self.weight(prefix + ".bias"))
        return self.operation(Opcode.RMS_NORM if rms else Opcode.LAYER_NORM, name, sources,
                              parameters=(self.float_bits(1e-6),), flags=int(zero_centered))
