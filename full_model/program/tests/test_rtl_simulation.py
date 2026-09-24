"""Validate fixture staging and reject invalid simulator evidence."""
import json
from pathlib import Path

import pytest

from prepare_rtl_simulation import RtlSimulation


def test_smoke_stages_full_tables(tmp_path):
    RtlSimulation.smoke(tmp_path)
    config = (tmp_path / 'simulator.txt').read_text()
    assert config.count('INPUT ') == 8
    assert config.count('OUTPUT ') == 2
    assert (tmp_path / 'program.bin').stat().st_size == 8 * 64
    assert (tmp_path / 'kernel_metadata.bin').stat().st_size == 8 * 32


def test_rejects_incomplete_smoke(tmp_path):
    (tmp_path / 'status.json').write_text(json.dumps({'complete': False}))
    with pytest.raises(ValueError, match='did not complete'):
        RtlSimulation.check_smoke(tmp_path)


def test_rejects_ambiguous_config_path():
    with pytest.raises(ValueError, match='whitespace'):
        RtlSimulation.path(Path('/tmp/two words'))


def test_comparison_requires_completion(tmp_path):
    RtlSimulation.smoke(tmp_path)
    (tmp_path / 'status.json').write_text(json.dumps({'complete': False}))
    with pytest.raises(ValueError, match='Complete RTL execution'):
        RtlSimulation.compare(tmp_path, tmp_path, tmp_path / 'unused-reference.json')
