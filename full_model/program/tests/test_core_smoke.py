import math

import pytest

from run_core_smoke import CoreHardwareCheck


def test_fixture_payloads_and_independent_expected(tmp_path):
    check = CoreHardwareCheck(tmp_path)
    assert len(check.payloads) == 8
    assert all(len(data) == check.graph.tensors[tid].logical_bytes for tid, data in check.payloads.items())
    assert len(check.graph.instructions) == 8
    outputs = {check.graph.tensors[tid].name: check.expected[i * 3:(i + 1) * 3]
               for i, tid in enumerate(check.graph.outputs)}
    check.check_outputs(outputs)
    outputs[check.graph.tensors[check.graph.outputs[0]].name][0] += 0.1
    with pytest.raises(RuntimeError, match="mismatch"):
        check.check_outputs(outputs)
    outputs[check.graph.tensors[check.graph.outputs[0]].name][0] = math.nan
    with pytest.raises(RuntimeError, match="mismatch"):
        check.check_outputs(outputs)
