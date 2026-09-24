"""Report cycle counts for a small RTL graph, never full-model latency."""
import json
import re
import sys
from pathlib import Path


class VirtualCoreComparison:
    @staticmethod
    def read(directory: Path) -> list[dict[str, int]]:
        rows = []
        for line in (directory / 'simulation.log').read_text().splitlines():
            if line.startswith('CORE_PERF '):
                rows.append({key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)})
        if len(rows) != 2 or [row['run'] for row in rows] != [0, 1]:
            raise ValueError(f'Missing consecutive runs: {directory}')
        return rows

    @classmethod
    def compare(cls, directory: Path) -> dict:
        results = []
        for latency in (0, 16, 64):
            serial_dir = directory / f'serial-{latency}'
            parallel_dir = directory / f'parallel-{latency}'
            for filename in ('trace.txt', 'results.txt'):
                baseline = (serial_dir / filename).read_bytes()
                if not baseline or baseline != (parallel_dir / filename).read_bytes():
                    raise ValueError(f'Intermediate/final parity failed: {latency}, {filename}')
            for serial, parallel in zip(cls.read(serial_dir), cls.read(parallel_dir)):
                if serial['read_latency'] != latency or parallel['read_latency'] != latency:
                    raise ValueError('Memory latency mismatch')
                if min(serial['cycles'], parallel['cycles']) <= 0:
                    raise ValueError('Invalid cycle count')
                results.append({'read_latency': latency, 'run': serial['run'],
                                'serial_cycles': serial['cycles'], 'parallel_cycles': parallel['cycles'],
                                'serial_axi_transactions': serial['axi_transactions'],
                                'parallel_axi_transactions': parallel['axi_transactions'],
                                'cycle_speedup': serial['cycles'] / parallel['cycles']})
        return {'scope': 'Seven-operation synthetic graph; behavioral AXI memory; not full-model simulation',
                'intermediate_and_final_bit_exact': True, 'runs': results}


if __name__ == '__main__':
    directory = Path(sys.argv[1])
    report = VirtualCoreComparison.compare(directory)
    (directory / 'performance.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
