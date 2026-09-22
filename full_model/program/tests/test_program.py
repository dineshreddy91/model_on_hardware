"""Full checkpoint lowering and fail-before-write loader regression tests."""
import json
from collections import Counter
from pathlib import Path

import pytest

from compiler import OpenJevCompiler
from loader import GraphHardware, HardwareCapabilities, ProgramLoader
from schema import InputProfile, Opcode, Storage

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "sim/validation/vector-scheduler/model-config.json"
MANIFEST = ROOT / "hbm_manifest.json"


@pytest.fixture
def graph():
    return OpenJevCompiler(CONFIG, MANIFEST).compile(InputProfile())


def capabilities(graph, opcodes=None):
    return HardwareCapabilities(abi=graph.format, opcodes=graph.required_opcodes if opcodes is None else opcodes,
                                max_instructions=4096, max_tensors=4096, model_revision=graph.model_revision,
                                manifest_sha256=graph.manifest_sha256)


class RecordingHardware(GraphHardware):
    def __init__(self, caps):
        self.caps = caps
        self.uploads = []
        self.starts = []

    def capabilities(self):
        return self.caps

    def upload(self, instructions, tensors):
        self.uploads.append((instructions, tensors))

    def start(self, instruction_count, tensor_count):
        self.starts.append((instruction_count, tensor_count))


def test_entire_checkpoint_and_operator_counts(graph):
    assert len(graph.covered_weights) == 732
    counts = Counter(i.opcode for i in graph.instructions)
    assert counts[Opcode.ATTENTION] == 18
    assert counts[Opcode.GATED_DELTA] == 18
    assert counts[Opcode.GELU_ERF] == 1
    assert counts[Opcode.GELU_TANH] == 12
    assert counts[Opcode.END] == 1
    assert len(graph.instructions) == 1291
    assert len(graph.input_ids) == 11
    graph.validate_dataflow()


def test_attention_geometry_and_gate_layout(graph):
    attentions = [i for i in graph.instructions if i.opcode == Opcode.ATTENTION]
    for op in attentions[:12]:
        assert op.parameters == (196, 196, 64, 12, 12)
        assert op.flags == 0
    for op in attentions[12:]:
        assert op.parameters == (128, 128, 256, 8, 2)
        assert op.flags == 3
    gates = [t for t in graph.tensors if t.storage == Storage.VIEW and t.shape == (128, 8, 256)]
    assert len(gates) == 12
    assert {t.offset for t in gates} == {0, 1024}
    assert all(t.strides == (16384, 2048, 4) for t in gates)


def test_load_and_unsupported_operator_no_writes(graph, tmp_path):
    graph.write(tmp_path)
    hardware = RecordingHardware(capabilities(graph, {Opcode.LINEAR_I8}))
    with pytest.raises(ValueError, match="Missing FPGA operators"):
        ProgramLoader(tmp_path).load(hardware)
    assert hardware.uploads == [] and hardware.starts == []
    hardware = RecordingHardware(capabilities(graph))
    loaded = ProgramLoader(tmp_path).load(hardware)
    assert len(hardware.uploads) == 1
    assert hardware.starts == []
    assert loaded.covered_weights == graph.covered_weights


@pytest.mark.parametrize("filename", ["program.bin", "program.json", "tensors.bin"])
def test_corrupted_artifact_rejected(graph, tmp_path, filename):
    graph.write(tmp_path)
    path = tmp_path / filename
    path.write_bytes(path.read_bytes() + b"x")
    hardware = RecordingHardware(capabilities(graph))
    with pytest.raises(ValueError, match="checksum"):
        ProgramLoader(tmp_path).load(hardware)
    assert hardware.uploads == []


def test_weight_identity_rejected(graph, tmp_path):
    graph.write(tmp_path)
    caps = capabilities(graph).model_copy(update={"manifest_sha256": "0"*64})
    with pytest.raises(ValueError, match="identity"):
        ProgramLoader(tmp_path).validate(caps)


def test_live_allocation_overlap_rejected(graph):
    roots = [t for t in graph.tensors if t.storage == Storage.INPUT]
    victim = roots[1]
    graph.tensors[victim.id] = victim.model_copy(update={"base": roots[0].base})
    with pytest.raises(ValueError, match="Overlapping"):
        graph.validate_dataflow()


def test_too_small_allocation_rejected(graph):
    root = graph.tensors[graph.input_ids[0]]
    graph.tensors[root.id] = root.model_copy(update={"extent": 0})
    with pytest.raises(ValueError, match="smaller"):
        graph.validate_dataflow()


@pytest.mark.parametrize("field,value", [("linear_conv_kernel_dim", 3), ("rms_norm_eps", 1e-5),
                                        ("attn_output_gate", False)])
def test_changed_architecture_rejected(tmp_path, field, value):
    config = json.loads(CONFIG.read_text())
    config["text_config"][field] = value
    path = tmp_path / "config.json"
    path.write_text(json.dumps(config))
    with pytest.raises(ValueError, match="semantics"):
        OpenJevCompiler(path, MANIFEST)


def test_small_profile():
    graph = OpenJevCompiler(CONFIG, MANIFEST).compile(InputProfile(grid_height=4, grid_width=6, text_tokens=16))
    graph.validate_dataflow()
    assert len(graph.covered_weights) == 732


@pytest.mark.parametrize("profile", [{"grid_height": 3}, {"text_tokens": 49},
                                   {"grid_height": 256, "grid_width": 256}])
def test_invalid_profile(profile):
    with pytest.raises(ValueError):
        InputProfile(**profile)
