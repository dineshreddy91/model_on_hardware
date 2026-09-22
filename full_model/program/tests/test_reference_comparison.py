import hashlib
from types import SimpleNamespace

import pytest

from full_model.host.compare_reference import OfflineReference


def fixture():
    graph = SimpleNamespace(model_revision='revision', manifest_sha256='manifest')
    reference = OfflineReference(execution='offline_cpu_reference_only', model_revision='revision',
        hbm_manifest_sha256='manifest', input_sha256={'1': hashlib.sha256(b'input').hexdigest()},
        outputs={'score': [1., 2., 3.]}, fpga_execution=False)
    return graph, reference


def test_reference_metrics():
    graph, reference = fixture()
    result = reference.compare(graph, {1: b'input'}, {'score': [1., 2., 3.25]})
    assert result['metrics']['score']['max_absolute_error'] == .25
    assert result['metrics']['score']['argmax_matches']


@pytest.mark.parametrize('actual', [{'score': [1.]}, {'different': [1., 2., 3.]}, {'score': [1., float('nan'), 3.]}])
def test_invalid_outputs_rejected(actual):
    graph, reference = fixture()
    with pytest.raises(ValueError):
        reference.compare(graph, {1: b'input'}, actual)


def test_other_inputs_rejected():
    graph, reference = fixture()
    with pytest.raises(ValueError, match='different input'):
        reference.compare(graph, {1: b'other'}, {'score': [1., 2., 3.]})
