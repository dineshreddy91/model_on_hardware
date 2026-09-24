"""Evidence checks reject incomplete runs and numerical mismatches."""
import json
from pathlib import Path

import pytest

from full_model.tools.check_virtual_core import VirtualCoreComparison


def make_evidence(root: Path):
    for revision, cycles in [('serial', 100), ('parallel', 80)]:
        for latency in (0, 16, 64):
            directory = root / f'{revision}-{latency}'
            directory.mkdir()
            (directory / 'simulation.log').write_text(''.join(
                f'CORE_PERF run={run} read_latency={latency} cycles={cycles} axi_transactions=10\n'
                for run in (0, 1)))
            for name in ('trace.txt', 'results.txt'):
                (directory / name).write_text('3f800000\n')


def test_virtual_comparison(tmp_path):
    make_evidence(tmp_path)
    report = VirtualCoreComparison.compare(tmp_path)
    assert len(report['runs']) == 6
    assert all(row['cycle_speedup'] == 1.25 for row in report['runs'])
    json.dumps(report)


@pytest.mark.parametrize('failure', ['trace', 'missing_run', 'latency'])
def test_rejects_invalid_evidence(tmp_path, failure):
    make_evidence(tmp_path)
    directory = tmp_path / 'parallel-64'
    if failure == 'trace':
        (directory / 'trace.txt').write_text('40000000\n')
    elif failure == 'missing_run':
        (directory / 'simulation.log').write_text('')
    else:
        path = directory / 'simulation.log'
        path.write_text(path.read_text().replace('read_latency=64', 'read_latency=0'))
    with pytest.raises(ValueError):
        VirtualCoreComparison.compare(tmp_path)
