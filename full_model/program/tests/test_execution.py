"""Execution metadata must cover the full graph and reject invalid dimensions."""
import struct
from pathlib import Path

import pytest

from compiler import OpenJevCompiler
from execution import ExecutionPlan
from schema import InputProfile, Opcode

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def graph():
    return OpenJevCompiler(ROOT / "sim/validation/vector-scheduler/model-config.json",
                          ROOT / "hbm_manifest.json").compile(InputProfile())


def test_entire_graph_kernel_metadata(graph):
    plan = ExecutionPlan(graph)
    assert len(plan.metadata) == 1291
    for instruction, metadata in zip(graph.instructions, plan.metadata):
        words = struct.unpack("<8I", metadata.encode())
        checksum = 0x4F4A4D31
        for word in words[:-1]:
            checksum ^= word
        assert checksum == words[-1]
        if instruction.opcode == Opcode.ROPE:
            assert metadata.dimensions[-1] == 64
        if instruction.opcode == Opcode.LINEAR_I8:
            assert metadata.weight_base == graph.tensors[instruction.sources[1]].base


def test_binary_broadcast_shape_rejected(graph):
    operations = list(graph.instructions)
    i = next(i for i, op in enumerate(operations) if op.opcode == Opcode.ADD and op.flags == 0)
    operations[i] = operations[i].model_copy(update={"flags": 1})
    with pytest.raises(ValueError, match="Broadcast geometry"):
        ExecutionPlan(graph.model_copy(update={"instructions": operations}))


def test_rotary_shape_rejected(graph):
    operations = list(graph.instructions)
    i = next(i for i, op in enumerate(operations) if op.opcode == Opcode.ROPE)
    operations[i] = operations[i].model_copy(update={"parameters": (65,)})
    with pytest.raises(ValueError, match="Rotary inputs"):
        ExecutionPlan(graph.model_copy(update={"instructions": operations}))


def test_matrix_layout_rejected(graph):
    operations = list(graph.instructions)
    i = next(i for i, op in enumerate(operations) if op.opcode == Opcode.LINEAR_I8)
    batches, rows, columns = operations[i].parameters
    operations[i] = operations[i].model_copy(update={"parameters": (batches, rows, columns - 1)})
    with pytest.raises(ValueError, match="Matrix geometry"):
        ExecutionPlan(graph.model_copy(update={"instructions": operations}))


@pytest.mark.parametrize("opcode", [Opcode.ATTENTION, Opcode.GATED_DELTA])
def test_head_geometry_rejected(graph, opcode):
    operations = list(graph.instructions)
    i = next(i for i, op in enumerate(operations) if op.opcode == opcode)
    parameters = list(operations[i].parameters)
    parameters[0] -= 1
    operations[i] = operations[i].model_copy(update={"parameters": tuple(parameters)})
    with pytest.raises(ValueError, match="geometry"):
        ExecutionPlan(graph.model_copy(update={"instructions": operations}))
