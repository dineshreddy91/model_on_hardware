"""Offline CPU numerical oracle for validation, never imported by the FPGA runner.

This is a quantized graph reference, not native checkpoint inference or a CPU
performance benchmark. FP32 reduction orders and transcendental approximations
can differ from RTL. Comparisons must report error rather than assume bit parity.
"""
import hashlib
import json
import math
import platform
import struct
import sys
from pathlib import Path

import torch
import torch.nn.functional as F
from safetensors import safe_open

from execution import ExecutionPlan
from ir import GraphProgram
from schema import DType, Opcode, Storage


class QuantizedReference:
    DTYPES = {DType.INT8: torch.int8, DType.INT32: torch.int32,
              DType.FLOAT16: torch.float16, DType.FLOAT32: torch.float32}

    def __init__(self, graph: GraphProgram):
        self.graph = graph
        ExecutionPlan(graph)
        self.values: dict[int, torch.Tensor] = {}
        self.last_use = {}
        for index, instruction in enumerate(graph.instructions):
            for tid in instruction.sources + instruction.destinations:
                self.last_use[graph.tensors[tid].root] = index
        for tid in graph.outputs:
            self.last_use[graph.tensors[tid].root] = len(graph.instructions)

    def tensor(self, tid):
        descriptor = self.graph.tensors[tid]
        root = self.values[descriptor.root]
        return root.as_strided(descriptor.shape,
            tuple(stride // descriptor.dtype.byte_size for stride in descriptor.strides),
            descriptor.offset // descriptor.dtype.byte_size)

    @staticmethod
    def recurrence(q, k, v, g, beta):
        # Independent vectorized per-token formulation of the recurrent rule.
        q = q * torch.rsqrt((q * q).sum(-1, keepdim=True) + 1e-6) / math.sqrt(q.shape[-1])
        k = k * torch.rsqrt((k * k).sum(-1, keepdim=True) + 1e-6)
        state = torch.zeros((q.shape[1], q.shape[2], v.shape[2]), dtype=torch.float32)
        outputs = []
        for t in range(q.shape[0]):
            state = state * torch.exp(g[t])[:, None, None]
            prediction = (state * k[t, :, :, None]).sum(-2)
            delta = (v[t] - prediction) * beta[t, :, None]
            state = state + k[t, :, :, None] * delta[:, None, :]
            outputs.append((state * q[t, :, :, None]).sum(-2))
        return torch.stack(outputs), state

    @staticmethod
    def evaluate(instruction, src):
        op, flags = instruction.opcode, instruction.flags
        x = src[0]
        if op == Opcode.QUANTIZE:
            peak = x.abs().amax(-1, keepdim=True)
            scale = (peak * torch.tensor(1 / 127, dtype=torch.float32)).clamp_min(torch.finfo(torch.float32).tiny)
            scale = torch.where(peak == 0, torch.ones_like(scale), scale)
            return (torch.round(x * scale.reciprocal()).clamp(-127, 127).to(torch.int8), scale.squeeze(-1))
        if op == Opcode.LINEAR_I8:
            # Binary64 sums of integer products are exact for these bounded shapes.
            return ((x.double() @ src[1].reshape(src[1].shape[0], -1).double().T).to(torch.int32),)
        if op == Opcode.DEQUANTIZE:
            return ((x.double() * src[2].double()).float() * src[1].float().unsqueeze(-1),)
        if op in (Opcode.ADD, Opcode.MULTIPLY):
            y = src[1].float()
            if flags == 2:
                y = y.unsqueeze(-1)
            return ((x.float() + y) if op == Opcode.ADD else (x.float() * y),)
        if op in (Opcode.LAYER_NORM, Opcode.RMS_NORM):
            epsilon = struct.unpack('<f', struct.pack('<I', instruction.parameters[0]))[0]
            gamma = src[1].float() + (1 if flags else 0)
            if op == Opcode.LAYER_NORM:
                return (F.layer_norm(x.float(), (x.shape[-1],), gamma, src[2].float(), epsilon),)
            return (x.float() * torch.rsqrt(x.float().square().mean(-1, keepdim=True) + epsilon) * gamma,)
        unary = {Opcode.SILU: F.silu, Opcode.GELU_TANH: lambda t: F.gelu(t, approximate='tanh'),
                 Opcode.GELU_ERF: F.gelu, Opcode.SIGMOID: torch.sigmoid, Opcode.EXP: torch.exp,
                 Opcode.SOFTPLUS: F.softplus, Opcode.NEGATE: torch.neg,
                 Opcode.SOFTMAX: lambda t: torch.softmax(t, dim=-1)}
        if op in unary:
            return (unary[op](x.float()),)
        if op == Opcode.EMBEDDING:
            ids = x.long()
            return (src[1][ids].float() * src[2][ids].float().unsqueeze(-1),)
        if op == Opcode.INTERPOLATE:
            indices = src[2].long()
            corners = x[indices].float() * src[1][indices].float().unsqueeze(-1)
            return ((corners * src[3].unsqueeze(-1)).sum(1),)
        if op == Opcode.ROPE:
            width = instruction.parameters[0]
            rotated = torch.cat((-x[..., width // 2:width], x[..., :width // 2]), dim=-1)
            result = x.clone()
            result[..., :width] = x[..., :width] * src[1][:, None, :] + rotated * src[2][:, None, :]
            return (result,)
        if op == Opcode.SCATTER_IMAGE:
            result = x.clone()
            result[src[2].long()] = src[1]
            return (result,)
        if op == Opcode.GATHER_LAST:
            return (x[src[1].long()],)
        if op == Opcode.CAUSAL_CONV:
            _, channels, kernel = instruction.parameters
            weights = src[1].float() * src[2].float()[:, None, None]
            result = F.conv1d(F.pad(x.T[None], (kernel - 1, 0)), weights, groups=channels)
            return (result[0].T,)
        if op == Opcode.ATTENTION:
            _, _, width, heads, kv_heads = instruction.parameters
            q, k, v = x.transpose(0, 1), src[1].transpose(0, 1), src[2].transpose(0, 1)
            k = k.repeat_interleave(heads // kv_heads, 0)
            v = v.repeat_interleave(heads // kv_heads, 0)
            scores = (q @ k.transpose(-1, -2)) / math.sqrt(width)
            if flags & 1:
                scores.masked_fill_(torch.ones(scores.shape[-2:], dtype=torch.bool).triu(1), -torch.inf)
            if flags & 2:
                scores.masked_fill_(~src[3].bool()[None, None, :], -torch.inf)
            return ((torch.softmax(scores, -1) @ v).transpose(0, 1),)
        if op == Opcode.GATED_DELTA:
            return QuantizedReference.recurrence(*src)
        raise ValueError(f'Unsupported reference opcode {op}')

    @torch.no_grad()
    def run(self, checkpoint: Path, manifest_path: Path, inputs: Path, output: Path):
        manifest_bytes = manifest_path.read_bytes()
        if hashlib.sha256(manifest_bytes).hexdigest() != self.graph.manifest_sha256:
            raise ValueError('Reference manifest mismatch')
        manifest = json.loads(manifest_bytes)
        expected = {item['name']: item['sha256'] for item in manifest['tensors']}
        with safe_open(checkpoint, framework='pt', device='cpu') as weights:
            for tensor in self.graph.tensors:
                if tensor.storage != Storage.WEIGHT:
                    continue
                value = weights.get_tensor(tensor.name).reshape(tensor.shape).contiguous()
                if value.dtype != self.DTYPES[tensor.dtype] or hashlib.sha256(value.numpy().tobytes()).hexdigest() != expected[tensor.name]:
                    raise ValueError(f'Reference weight mismatch: {tensor.name}')
                self.values[tensor.id] = value
        input_hashes = {}
        for tid in self.graph.input_ids:
            descriptor = self.graph.tensors[tid]
            payload = (inputs / f'input_{tid}.bin').read_bytes()
            if len(payload) != descriptor.logical_bytes:
                raise ValueError('Reference input size mismatch')
            self.values[tid] = torch.frombuffer(bytearray(payload), dtype=self.DTYPES[descriptor.dtype]).reshape(descriptor.shape)
            input_hashes[str(tid)] = hashlib.sha256(payload).hexdigest()
        trace = []
        for index, instruction in enumerate(self.graph.instructions):
            if instruction.opcode == Opcode.END:
                break
            result = self.evaluate(instruction, [self.tensor(tid) for tid in instruction.sources])
            if len(result) != len(instruction.destinations):
                raise ValueError('Reference output count mismatch')
            for tid, value in zip(instruction.destinations, result):
                descriptor = self.graph.tensors[tid]
                value = value.reshape(descriptor.shape).contiguous()
                if value.dtype != self.DTYPES[descriptor.dtype] or not torch.isfinite(value).all():
                    raise ValueError(f'Invalid reference result at {instruction.stage}')
                self.values[tid] = value
            trace.append({'tag': instruction.tag, 'stage': instruction.stage,
                          'max_abs': [float(value.abs().max()) for value in result]})
            for root in set(self.graph.tensors[tid].root for tid in instruction.sources + instruction.destinations):
                if self.last_use[root] == index:
                    self.values.pop(root, None)
            if index % 100 == 0:
                print(f'Offline reference {index}/{len(self.graph.instructions)}: {instruction.stage}', flush=True)
        output.write_text(json.dumps({'execution': 'offline_cpu_reference_only',
            'reference_environment': {
                'source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'python_version': platform.python_version(), 'torch_version': torch.__version__,
                'cpu_capability': torch.backends.cpu.get_cpu_capability(),
                'torch_num_threads': torch.get_num_threads(),
                'float32_matmul_precision': torch.get_float32_matmul_precision(),
                'mkldnn_enabled': torch.backends.mkldnn.enabled,
            },
            'model_revision': self.graph.model_revision, 'input_sha256': input_hashes,
            'hbm_manifest_sha256': self.graph.manifest_sha256,
            'outputs': {self.graph.tensors[tid].name: self.tensor(tid).flatten().tolist() for tid in self.graph.outputs},
            'trace': trace, 'fpga_execution': False, 'latency_comparison': False}, indent=2) + '\n')


if __name__ == '__main__':
    if len(sys.argv) != 6:
        raise SystemExit('Usage: reference_graph.py PROGRAM_JSON CHECKPOINT MANIFEST INPUT_DIRECTORY OUTPUT_JSON')
    torch.set_num_threads(8)
    QuantizedReference(GraphProgram.model_validate_json(Path(sys.argv[1]).read_bytes())).run(*(Path(p) for p in sys.argv[2:]))
