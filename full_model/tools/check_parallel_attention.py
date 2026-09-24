"""Compare serial and parallel attention on identical stalled memory fixtures."""
import json
import re
import sys
from pathlib import Path


class AttentionPerformance:
    @staticmethod
    def read(path: Path) -> dict[int, dict[str, int]]:
        cases = {}
        for line in path.read_text().splitlines():
            if line.startswith('PERF '):
                values = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
                cases[values['case']] = values
        return cases

    @classmethod
    def compare(cls, directory: Path) -> None:
        serial = cls.read(directory / 'simulation-0.log')
        parallel = cls.read(directory / 'simulation-4.log')
        if not serial or serial.keys() != parallel.keys():
            raise ValueError('Missing serial/parallel performance cases')
        rows = []
        for key, baseline in serial.items():
            actual = parallel[key]
            for field in ('queries', 'keys', 'dim'):
                if baseline[field] != actual[field]:
                    raise ValueError('Mismatched performance geometry')
            rows.append({**actual, 'serial_cycles': baseline['cycles'],
                         'serial_reads': baseline['reads'],
                         'cycle_speedup': baseline['cycles'] / actual['cycles']})
        large = [row for row in rows if row['queries'] >= 4]
        speedup = sum(row['serial_cycles'] for row in large) / sum(row['cycles'] for row in large)
        if speedup <= 1:
            raise ValueError('Parallel attention does not improve multiquery cycle count')
        report = {'scope': 'RTL simulation only; fixed 64-cycle memory response latency, stalls enabled',
                  'bit_exact_against_serial': True, 'multiquery_aggregate_cycle_speedup': speedup,
                  'cases': rows}
        (directory / 'performance.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f'PASS serial parity; multiquery aggregate cycle speedup {speedup:.3f}x (simulation only)')


if __name__ == '__main__':
    AttentionPerformance.compare(Path(sys.argv[1]))
