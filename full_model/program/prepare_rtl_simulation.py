"""Validate full-model artifacts and stage byte-only RTL simulator inputs."""
import hashlib
import json
import math
import struct
import sys
from pathlib import Path

from full_model.host.compare_reference import OfflineReference

from core_fixture import CoreFixture
from execution import ExecutionPlan
from ir import GraphProgram
from loader import HardwareCapabilities, ProgramLoader
from schema import DType


class RtlSimulation:
    @staticmethod
    def digest(path: Path) -> str:
        result = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(4 << 20), b''):
                result.update(chunk)
        return result.hexdigest()

    @staticmethod
    def path(path: Path) -> str:
        value = str(path.resolve())
        if any(character.isspace() for character in value):
            raise ValueError('Simulator config paths must not contain whitespace')
        return value

    @classmethod
    def write(cls, graph: GraphProgram, program: Path, output: Path, banks, inputs):
        output.mkdir(parents=True, exist_ok=True)
        lines = [cls.path(program), cls.path(output)]
        for bank, path in banks:
            lines.append(f'BANK {bank} {cls.path(path)}')
        for tid, path in inputs:
            tensor = graph.tensors[tid]
            if tensor.offset or tensor.id != tensor.root:
                raise ValueError('Input must be a root tensor')
            if path.stat().st_size != tensor.logical_bytes:
                raise ValueError('Input byte length mismatch')
            lines.append(f'INPUT {tensor.base} {cls.path(path)}')
        for tid in graph.outputs:
            tensor = graph.tensors[tid]
            if tensor.dtype != DType.FLOAT32 or tensor.offset or tensor.strides != tensor.contiguous_strides(tensor.shape, tensor.dtype):
                raise ValueError('Output requires contiguous root FP32 tensor')
            lines.append(f'OUTPUT {tensor.base} {math.prod(tensor.shape)}')
        (output / 'simulator.txt').write_text('\n'.join(lines) + '\n')
        (output / 'graph.json').write_text(graph.model_dump_json())

    @classmethod
    def smoke(cls, output: Path):
        CoreFixture().generate(output)
        graph = GraphProgram.model_validate_json((output / 'program.json').read_bytes())
        inputs = [(int(p.stem), p) for p in sorted((output / 'payloads').glob('*.bin'))]
        cls.write(graph, output, output, [], inputs)

    @classmethod
    def prepare(cls, program: Path, hbm: Path, inputs: Path, output: Path):
        graph = GraphProgram.model_validate_json((program / 'program.json').read_bytes())
        graph = ProgramLoader(program).validate(HardwareCapabilities(
            abi=graph.format, opcodes=frozenset(graph.required_opcodes), max_instructions=4096,
            max_tensors=4096, model_revision=graph.model_revision, manifest_sha256=graph.manifest_sha256))
        metadata = b''.join(item.encode() for item in ExecutionPlan(graph).metadata)
        if metadata != (program / 'kernel_metadata.bin').read_bytes():
            raise ValueError('Kernel metadata does not match graph')
        manifest_path = hbm / 'hbm_manifest.json'
        if cls.digest(manifest_path) != graph.manifest_sha256:
            raise ValueError('Weight manifest identity mismatch')
        manifest = json.loads(manifest_path.read_text())
        if sorted(item['bank'] for item in manifest['bank_images']) != list(range(32)):
            raise ValueError('Expected exactly 32 bank images')
        banks = []
        for item in manifest['bank_images']:
            path = hbm / f"hbm_bank_{item['bank']:02d}.bin"
            if path.stat().st_size != item['bytes'] or cls.digest(path) != item['sha256']:
                raise ValueError(f'Bank checksum mismatch: {path}')
            banks.append((item['bank'], path))
        prepared = json.loads((inputs / 'inputs.json').read_text())
        if prepared['model_revision'] != graph.model_revision or prepared['learned_cpu_computation']:
            raise ValueError('Input model identity or CPU computation mismatch')
        records = prepared['inputs']
        if sorted(item['tensor_id'] for item in records) != sorted(graph.input_ids):
            raise ValueError('Input tensor set mismatch')
        payloads = []
        for item in records:
            path = inputs / item['file']
            if path.stat().st_size != item['bytes'] or cls.digest(path) != item['sha256']:
                raise ValueError('Input checksum mismatch')
            payloads.append((item['tensor_id'], path))
        cls.write(graph, program, output, banks, payloads)
        provenance = {'scope': 'Complete compiled model in RTL simulation; no CPU model fallback',
                      'model_revision': graph.model_revision, 'manifest_sha256': graph.manifest_sha256,
                      'program_sha256': cls.digest(program / 'program.bin'),
                      'instructions': len(graph.instructions), 'tensors': len(graph.tensors),
                      'input': prepared}
        (output / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
        print(json.dumps({key: value for key, value in provenance.items() if key != 'input'}))

    @classmethod
    def compare(cls, output: Path, input_directory: Path, reference_path: Path):
        status = json.loads((output / 'status.json').read_text())
        graph = GraphProgram.model_validate_json((output / 'graph.json').read_bytes())
        if (not status['complete'] or status['fault'] or status['cpu_model_fallback']
                or status['instructions_retired'] != len(graph.instructions) - 1):
            raise ValueError('Complete RTL execution required before comparison')
        raw = (output / 'outputs.bin').read_bytes()
        expected_bytes = sum(graph.tensors[tid].logical_bytes for tid in graph.outputs)
        if len(raw) != expected_bytes:
            raise ValueError('Incomplete RTL output payload')
        outputs = {}
        offset = 0
        for tid in graph.outputs:
            tensor = graph.tensors[tid]
            count = math.prod(tensor.shape)
            outputs[tensor.name] = list(struct.unpack_from(f'<{count}f', raw, offset))
            offset += count * 4
        prepared = json.loads((input_directory / 'inputs.json').read_text())
        inputs = {item['tensor_id']: (input_directory / item['file']).read_bytes()
                  for item in prepared['inputs']}
        comparison = OfflineReference.from_file(reference_path).compare(graph, inputs, outputs)
        result = {**status, 'outputs': outputs, 'offline_reference_comparison': comparison,
                  'scope': 'Functional RTL simulation with behavioral memory; not physical FPGA latency'}
        (output / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))

    @staticmethod
    def check_smoke(output: Path):
        status = json.loads((output / 'status.json').read_text())
        if not status['complete'] or status['instructions_retired'] != 7:
            raise ValueError('Smoke RTL graph did not complete')
        raw = (output / 'outputs.bin').read_bytes()
        if len(raw) != 24:
            raise ValueError('Smoke output length')
        (output / 'results.txt').write_text(''.join(f'{word:08x}\n' for word in struct.unpack('<6I', raw)))
        CoreFixture.check(output)


if __name__ == '__main__':
    mode, *paths = sys.argv[1:]
    getattr(RtlSimulation, mode)(*(Path(path) for path in paths))
