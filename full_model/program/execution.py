"""Static tensor geometry for FPGA kernel dispatch; no model arithmetic runs here."""
import math
import struct
from pathlib import Path

from pydantic import BaseModel, ConfigDict

from ir import GraphProgram
from schema import DType, Opcode, Storage, Tensor


class KernelMetadata(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")
    dimensions: tuple[int, int, int, int]
    dtypes: int
    weight_base: int = 0
    epsilon: int = 0

    def encode(self) -> bytes:
        words = [*self.dimensions, self.dtypes, self.weight_base, self.epsilon]
        checksum = 0x4F4A4D31
        for word in words:
            if not 0 <= word <= 0xFFFFFFFF:
                raise ValueError("Kernel metadata exceeds word size")
            checksum ^= word
        return struct.pack("<8I", *words, checksum)


class ExecutionPlan:
    def __init__(self, graph: GraphProgram):
        graph.validate_dataflow()
        self.graph = graph
        self.metadata = [self._lower(instruction) for instruction in graph.instructions]

    @staticmethod
    def require(condition: bool, message: str):
        if not condition:
            raise ValueError(message)

    @staticmethod
    def contiguous(tensor: Tensor):
        return tensor.strides == Tensor.contiguous_strides(tensor.shape, tensor.dtype)

    def _lower(self, instruction):
        op = instruction.opcode
        if op == Opcode.END:
            return KernelMetadata(dimensions=(0, 0, 0, 0), dtypes=0)
        src = [self.graph.tensors[i] for i in instruction.sources]
        dst = [self.graph.tensors[i] for i in instruction.destinations]
        require = self.require
        dtypes = sum(t.dtype.code << (2 * i) for i, t in enumerate(src))
        dimensions = (math.prod(dst[0].shape[:-1]), dst[0].shape[-1], 0, 0)
        epsilon = 0
        base = 0
        require(len(dst) == (2 if op in (Opcode.QUANTIZE, Opcode.GATED_DELTA) else 1), "Destination count")
        if op == Opcode.QUANTIZE:
            require(len(src) == 1 and src[0].shape == dst[0].shape and src[0].dtype == DType.FLOAT32
                    and dst[0].dtype == DType.INT8 and dst[1].dtype == DType.FLOAT32
                    and math.prod(dst[1].shape) == dimensions[0] and dimensions[1] <= 4096, "Quantization geometry")
        elif op == Opcode.LINEAR_I8:
            batches, rows, columns = instruction.parameters
            require(len(src) == 2 and all(t.dtype == DType.INT8 for t in src)
                    and dst[0].dtype == DType.INT32 and 0 < columns <= 4096 and columns % 32 == 0
                    and 0 < rows <= 8192 and 0 < batches <= 4096
                    and math.prod(src[0].shape) == batches * columns
                    and src[0].shape[-1] == columns and src[1].shape[0] == rows
                    and math.prod(src[1].shape[1:]) == columns and math.prod(dst[0].shape) == batches * rows,
                    "Matrix geometry")
            require(src[1].storage == Storage.WEIGHT and self.contiguous(src[1]) and src[1].offset == 0,
                    "Matrix weights must be a contiguous checkpoint root")
            base = src[1].base
            dimensions = (batches, rows, columns, 0)
        elif op == Opcode.DEQUANTIZE:
            require(len(src) == 3 and src[0].shape == dst[0].shape
                    and [t.dtype for t in src] == [DType.INT32, DType.FLOAT32, DType.FLOAT16]
                    and math.prod(src[1].shape) == dimensions[0] and math.prod(src[2].shape) == dimensions[1],
                    "Dequantization geometry")
        elif op in (Opcode.ADD, Opcode.MULTIPLY):
            require(len(src) == 2 and src[0].shape == dst[0].shape and instruction.flags in (0, 1, 2), "Binary geometry")
            expected = math.prod(src[0].shape) if instruction.flags == 0 else dimensions[1] if instruction.flags == 1 else dimensions[0]
            require(math.prod(src[1].shape) == expected, "Broadcast geometry")
            if instruction.flags == 2:
                require(src[1].dtype == DType.INT32, "Row mask must contain INT32 booleans")
        elif op in (Opcode.LAYER_NORM, Opcode.RMS_NORM):
            require(len(src) == (3 if op == Opcode.LAYER_NORM else 2)
                    and src[0].shape == dst[0].shape and src[0].dtype == DType.FLOAT32
                    and all(t.shape == (dimensions[1],) for t in src[1:]), "Normalization geometry")
            require(instruction.flags in (0, 1) and (op == Opcode.RMS_NORM or instruction.flags == 0), "Normalization flags")
            epsilon, = instruction.parameters
        elif op in (Opcode.SILU, Opcode.GELU_TANH, Opcode.GELU_ERF, Opcode.SIGMOID,
                    Opcode.EXP, Opcode.SOFTPLUS, Opcode.NEGATE, Opcode.SOFTMAX):
            require(len(src) == 1 and src[0].shape == dst[0].shape
                    and src[0].dtype in (DType.FLOAT16, DType.FLOAT32) and instruction.flags == 0, "Unary geometry")
        elif op in (Opcode.EMBEDDING, Opcode.INTERPOLATE):
            embedding = op == Opcode.EMBEDDING
            require(len(src) == (3 if embedding else 4), "Table operand count")
            weights, scales = (src[1], src[2]) if embedding else (src[0], src[1])
            require(len(dst[0].shape) == 2 and len(weights.shape) == 2 and weights.shape[1] == dimensions[1]
                    and weights.dtype == DType.INT8 and scales.dtype == DType.FLOAT16
                    and math.prod(scales.shape) == weights.shape[0], "Table weight geometry")
            indices = src[0] if embedding else src[2]
            require(indices.dtype == DType.INT32 and indices.shape == ((dimensions[0],) if embedding else (dimensions[0], 4)), "Table indices")
            if not embedding:
                require(src[3].dtype == DType.FLOAT32 and src[3].shape == indices.shape, "Interpolation coefficients")
            dimensions = (*dimensions[:2], weights.shape[0], 0)
        elif op == Opcode.SCATTER_IMAGE:
            require(len(src) == 3 and len(src[0].shape) == 2 and src[0].shape == dst[0].shape
                    and len(src[1].shape) == 2 and src[1].shape[1] == dimensions[1]
                    and src[2].dtype == DType.INT32 and src[2].shape == (src[1].shape[0],), "Image insertion geometry")
            dimensions = (*dimensions[:2], 0, src[1].shape[0])
        elif op == Opcode.GATHER_LAST:
            require(len(src) == 2 and len(src[0].shape) == 2 and dst[0].shape == (1, src[0].shape[1])
                    and src[1].dtype == DType.INT32 and src[1].shape == (1,), "Gather geometry")
            dimensions = (*src[0].shape, 0, 0)
        elif op == Opcode.ROPE:
            require(len(src) == 3 and len(src[0].shape) == 3 and src[0].shape == dst[0].shape, "Rotary geometry")
            nt, heads, width = src[0].shape
            rotary, = instruction.parameters
            require(0 < rotary <= width and rotary % 2 == 0 and heads <= 64 and width <= 256
                    and src[1].shape == src[2].shape == (nt, rotary)
                    and all(t.dtype == DType.FLOAT32 for t in src), "Rotary inputs")
            dimensions = (nt, heads, width, rotary)
        elif op == Opcode.CAUSAL_CONV:
            nt, width, kernel = instruction.parameters
            require(len(src) == 3 and src[0].shape == dst[0].shape == (nt, width)
                    and src[1].shape == (width, 1, kernel) and math.prod(src[2].shape) == width
                    and [t.dtype for t in src] == [DType.FLOAT32, DType.INT8, DType.FLOAT16], "Convolution geometry")
            dimensions = (nt, width, kernel, 0)
        elif op == Opcode.ATTENTION:
            require(len(instruction.parameters) == 5 and instruction.flags in (0, 1, 2, 3), "Attention parameters")
            nt, nk, width, heads, kv_heads = instruction.parameters
            require(0 < nt <= 4096 and 0 < nk <= 4096 and 0 < width <= 256
                    and width & (width - 1) == 0 and 0 < kv_heads <= heads <= 64
                    and heads % kv_heads == 0 and (heads // kv_heads) & (heads // kv_heads - 1) == 0,
                    "Attention capacity")
            require(len(src) == (4 if instruction.flags & 2 else 3)
                    and all(t.dtype == DType.FLOAT32 for t in src[:3])
                    and src[0].shape == dst[0].shape == (nt, heads, width)
                    and src[1].shape == src[2].shape == (nk, kv_heads, width), "Attention geometry")
            require(not instruction.flags & 1 or nt == nk, "Causal attention lengths")
            if instruction.flags & 2:
                require(src[3].dtype == DType.INT32 and math.prod(src[3].shape) == nk, "Attention mask")
            dimensions = (0, 0, 0, 0)
        elif op == Opcode.GATED_DELTA:
            require(len(instruction.parameters) == 4 and instruction.flags == 3, "Recurrence parameters")
            nt, heads, kd, vd = instruction.parameters
            require(0 < nt <= 4096 and 0 < heads <= 64 and 0 < kd <= 128 and 0 < vd <= 128
                    and kd & (kd - 1) == 0 and vd & (vd - 1) == 0, "Recurrence capacity")
            require(len(src) == 5 and all(t.dtype == DType.FLOAT32 for t in src)
                    and src[0].shape == src[1].shape == (nt, heads, kd)
                    and src[2].shape == dst[0].shape == (nt, heads, vd)
                    and src[3].shape == src[4].shape == (nt, heads)
                    and dst[1].shape == (heads, kd, vd), "Recurrence geometry")
            dimensions = (0, 0, 0, 0)
        else:
            raise ValueError(f"No hardware kernel for {op}")
        if op not in (Opcode.QUANTIZE, Opcode.LINEAR_I8):
            require(all(t.dtype == DType.FLOAT32 for t in dst), "Floating output dtype")
        if op.value <= 15 and op != Opcode.LINEAR_I8:
            require(0 < dimensions[0] <= 262144 and 0 < dimensions[1] <= 8191, "Row adapter capacity")
        return KernelMetadata(dimensions=dimensions, dtypes=dtypes, weight_base=base, epsilon=epsilon)

    def write(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        payload = b"".join(item.encode() for item in self.metadata)
        (directory / "kernel_metadata.bin").write_bytes(payload)
        (directory / "kernel_metadata.mem").write_text("".join(
            item.encode()[::-1].hex() + "\n" for item in self.metadata))
