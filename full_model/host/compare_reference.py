"""Compare a completed FPGA request with an explicitly offline CPU oracle."""
import hashlib
import math
from pathlib import Path

from pydantic import BaseModel, ConfigDict


class OfflineReference(BaseModel):
    model_config = ConfigDict(extra='ignore')
    execution: str
    model_revision: str
    hbm_manifest_sha256: str
    input_sha256: dict[str, str]
    outputs: dict[str, list[float]]
    fpga_execution: bool

    def compare(self, graph, inputs: dict[int, bytes], actual: dict[str, list[float]]) -> dict:
        if self.execution != 'offline_cpu_reference_only' or self.fpga_execution:
            raise ValueError('Expected explicitly labelled offline reference')
        if self.model_revision != graph.model_revision or self.hbm_manifest_sha256 != graph.manifest_sha256:
            raise ValueError('Reference model provenance mismatch')
        hashes = {str(tid): hashlib.sha256(payload).hexdigest() for tid, payload in inputs.items()}
        if hashes != self.input_sha256:
            raise ValueError('Reference was generated from different input tensors')
        if self.outputs.keys() != actual.keys():
            raise ValueError('Reference output names differ')
        metrics = {}
        for name, expected in self.outputs.items():
            observed = actual[name]
            if not expected or len(observed) != len(expected) or not all(math.isfinite(x) for x in expected + observed):
                raise ValueError('Invalid comparison outputs')
            metrics[name] = {
                'max_absolute_error': max(abs(a - b) for a, b in zip(observed, expected)),
                'rmse': math.sqrt(sum((a - b)**2 for a, b in zip(observed, expected)) / len(expected)),
                'argmax_matches': max(range(len(observed)), key=observed.__getitem__) == max(range(len(expected)), key=expected.__getitem__),
                'reference': expected,
            }
        return {'reference_kind': self.execution, 'metrics': metrics,
                'acceptance': 'Measured differences; no model-wide numerical tolerance or safety accuracy established'}

    @classmethod
    def from_file(cls, path: Path):
        return cls.model_validate_json(path.read_bytes())
