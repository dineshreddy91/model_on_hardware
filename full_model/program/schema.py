"""Versioned tensor and instruction ABI for the FPGA graph program."""
import math
import struct
from enum import Enum, IntEnum

from pydantic import BaseModel, ConfigDict, Field, model_validator


class Opcode(IntEnum):
    QUANTIZE = 1
    LINEAR_I8 = 2
    DEQUANTIZE = 3
    ADD = 4
    MULTIPLY = 5
    LAYER_NORM = 6
    RMS_NORM = 7
    SILU = 8
    GELU_TANH = 9
    GELU_ERF = 10
    SIGMOID = 11
    EXP = 12
    SOFTPLUS = 13
    NEGATE = 14
    SOFTMAX = 15
    EMBEDDING = 16
    INTERPOLATE = 17
    ROPE = 18
    SCATTER_IMAGE = 19
    GATHER_LAST = 20
    CAUSAL_CONV = 21
    ATTENTION = 22
    GATED_DELTA = 23
    END = 255


class DType(str, Enum):
    INT8 = "int8"
    FLOAT16 = "float16"
    INT32 = "int32"
    FLOAT32 = "float32"

    @property
    def byte_size(self) -> int:
        return {self.INT8: 1, self.FLOAT16: 2, self.INT32: 4, self.FLOAT32: 4}[self]

    @property
    def code(self) -> int:
        return list(DType).index(self)


class Storage(str, Enum):
    WEIGHT = "weight"
    INPUT = "input"
    SCRATCH = "scratch"
    VIEW = "view"


class Tensor(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")
    id: int = Field(ge=0, lt=0xFFFFFFFF)
    name: str
    shape: tuple[int, ...]
    dtype: DType
    storage: Storage
    root: int = Field(ge=0)
    offset: int = Field(default=0, ge=0)
    strides: tuple[int, ...]
    base: int = Field(default=0, ge=0, lt=0x20000000)
    extent: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def validate_geometry(self) -> "Tensor":
        if not 1 <= len(self.shape) <= 4 or any(x <= 0 for x in self.shape):
            raise ValueError("Tensor rank must be 1..4 and dimensions positive")
        if len(self.strides) != len(self.shape) or any(x <= 0 for x in self.strides):
            raise ValueError("Positive byte strides must match rank")
        if self.offset % self.dtype.byte_size or any(x % self.dtype.byte_size for x in self.strides):
            raise ValueError("Tensor offsets/strides must be element aligned")
        if self.base % 4096:
            raise ValueError("Root base must be 4KiB aligned")
        if self.logical_bytes > 0xFFFFFFFF:
            raise ValueError("Tensor exceeds ABI length field")
        return self

    @property
    def logical_bytes(self) -> int:
        return math.prod(self.shape) * self.dtype.byte_size

    @property
    def span(self) -> int:
        return self.offset + sum((n - 1) * s for n, s in zip(self.shape, self.strides)) + self.dtype.byte_size

    @staticmethod
    def contiguous_strides(shape: tuple[int, ...], dtype: DType) -> tuple[int, ...]:
        stride = dtype.byte_size
        result = []
        for dimension in reversed(shape):
            result.append(stride)
            stride *= dimension
        return tuple(reversed(result))

    def encode(self) -> bytes:
        words = [self.id, self.dtype.code, list(Storage).index(self.storage), len(self.shape),
                 self.base, self.logical_bytes, self.root, self.offset]
        words += list(self.shape) + [0] * (4 - len(self.shape))
        words += list(self.strides) + [0] * (4 - len(self.strides))
        words += [self.extent] + [0] * 15
        return struct.pack("<32I", *words)


class Instruction(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")
    opcode: Opcode
    tag: int = Field(ge=0, lt=0xFFFFFFFF)
    stage: str
    sources: tuple[int, ...] = ()
    destinations: tuple[int, ...] = ()
    parameters: tuple[int, ...] = ()
    flags: int = Field(default=0, ge=0, lt=1 << 24)

    @model_validator(mode="after")
    def validate_fields(self) -> "Instruction":
        if len(self.sources) > 6 or len(self.destinations) > 2 or len(self.parameters) > 5:
            raise ValueError("Instruction exceeds fixed ABI fields")
        if any(x < 0 or x >= 0xFFFFFFFF for x in self.sources + self.destinations):
            raise ValueError("Invalid tensor ID")
        if any(x < 0 or x > 0xFFFFFFFF for x in self.parameters):
            raise ValueError("Parameter exceeds 32 bits")
        if self.opcode == Opcode.END and (self.sources or self.destinations or self.parameters or self.flags):
            raise ValueError("END must not contain operands")
        if self.opcode != Opcode.END and not self.destinations:
            raise ValueError("Compute instruction needs a destination")
        return self

    def encode(self) -> bytes:
        words = [int(self.opcode) | self.flags << 8, self.tag]
        words += list(self.destinations) + [0xFFFFFFFF] * (2 - len(self.destinations))
        words += list(self.sources) + [0xFFFFFFFF] * (6 - len(self.sources))
        words += list(self.parameters) + [0] * (5 - len(self.parameters))
        checksum = 0x4F4A5031
        for word in words:
            checksum ^= word
        return struct.pack("<16I", *words, checksum)


class InputProfile(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")
    grid_height: int = Field(default=14, ge=2, le=256)
    grid_width: int = Field(default=14, ge=2, le=256)
    text_tokens: int = Field(default=128, ge=1, le=4096)

    @model_validator(mode="after")
    def validate_grid(self) -> "InputProfile":
        if self.grid_height % 2 or self.grid_width % 2:
            raise ValueError("Image grid must support 2x2 spatial merging")
        if self.patch_tokens > 4096 or self.image_tokens >= self.text_tokens:
            raise ValueError("Image grid exceeds attention limits or leaves no text-token slots")
        return self

    @property
    def patch_tokens(self) -> int:
        return self.grid_height * self.grid_width

    @property
    def image_tokens(self) -> int:
        return self.patch_tokens // 4
