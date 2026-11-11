#!/usr/bin/env python3
"""Characterize the FU FIFO with the existing ECP5 timing harness."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import json
from pathlib import Path

from alu.measure import (
    ROOT, build_isolated, build_status, instantiate_ports, metric_cells, path_diagnostics, synth_cells,
)


MODES = ('registered', 'lutram', 'bram')
DEFAULT_SHAPES = [(64, depth) for depth in (4, 8, 16, 32, 64)] + [(128, 8)]


@dataclass(frozen=True)
class Fifo:
    width: int
    depth: int

    @property
    def name(self):
        return f'FIFO_{self.width}x{self.depth}'

    @property
    def rtl(self):
        return [Path(__file__).with_name('mdma_fifo.v').resolve()]

    @property
    def inputs(self):
        return [('reset', 1), ('i_in_data', self.width), ('i_in_valid', 1), ('o_out_take', 1)]

    @property
    def outputs(self):
        return [('i_in_take', 1), ('o_out_data', self.width), ('o_out_valid', 1)]

    def instantiate(self, mode, clock, input_bus, output_bus, _config):
        params = [f'.IMPLEMENTATION({MODES.index(mode)})',
                  f'.DEPTH({self.depth})', f'.WIDTH({self.width})']
        return instantiate_ports(self, 'mdma_fifo', params, clock, input_bus, output_bus)


def measure(fifo, mode, output, timeout, seed):
    result = {'unit': fifo.name, 'mode': mode, 'seed': seed, 'width': fifo.width, 'depth': fifo.depth}
    build_isolated(fifo, mode, output, timeout, result)
    if 'synthesis_resources' in result:
        cells = synth_cells(output / fifo.name / mode)
        payload = [cell['type'] for name, cell in cells.items()
                   if name.startswith('fu.') and ('.entries[' in name or '.entries.' in name)]
        counts = result['synthesis_resources']
        storage = (bool(counts.get('TRELLIS_DPR16X4')), bool(counts.get('DP16KD')))
        expected = (mode == 'lutram', mode == 'bram')
        mapped = (payload.count('TRELLIS_FF') == fifo.width * fifo.depth if mode == 'registered'
                  else 'TRELLIS_FF' not in payload)
        if storage != expected or not mapped:
            result['mapping_failure'] = f'payload did not map to {mode} storage'
    print(f'{fifo.name} {mode} · {build_status(result)}', flush=True)
    return result


def render_report(results):
    keys = sorted({key for row in results for key, used in row.get('resources', {}).items() if used})
    rows = ['# Isolated ECP5 FIFO measurements', '',
            'Timing is characterized without a frequency floor. Resource totals include the harness.',
            'Comparisons give registered baseline → candidate (raw delta, percentage delta).', '',
            '| FIFO | Mode | FU MHz | Scan MHz | Synthesis seconds | ' + ' | '.join(keys) + ' | Build |',
            '| --- | --- | ---: | ---: | ---: | ' + ' | '.join(['---:'] * len(keys)) + ' | --- |']
    baselines = {row['unit']: row for row in results if row['mode'] == 'registered'}
    for result in results:
        unit, mode = result['unit'], result['mode']
        items = [result] if mode == 'registered' else [baselines[unit], result]
        label = mode if mode == 'registered' else f'registered → {mode}'
        rows.append('| ' + ' | '.join([unit, label] + metric_cells(items, keys)) + ' |')
    return '\n'.join(rows + path_diagnostics(results)) + '\n'


def parse_shape(text):
    try:
        width, depth = map(int, text.lower().split('x'))
        if width >= 1 and depth >= 4:
            return width, depth
    except ValueError:
        pass
    raise argparse.ArgumentTypeError('use WIDTHxDEPTH with WIDTH >= 1 and DEPTH >= 4')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('shapes', type=parse_shape, nargs='*', metavar='WIDTHxDEPTH')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/rtl/fifo')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--seed', type=int, default=1)
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout < 1:
        parser.error('jobs and timeout must be positive')
    output = args.output.resolve()
    shapes = dict.fromkeys(args.shapes or DEFAULT_SHAPES)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        jobs = [pool.submit(measure, Fifo(*shape), mode, output, args.timeout, args.seed)
                for shape in shapes for mode in MODES]
        results = [job.result() for job in jobs]
    (output / 'report.json').write_text(json.dumps(results, indent=2) + '\n')
    report = output / 'report.md'
    report.write_text(render_report(results))
    print(report)
    return int(any(build_status(result) != 'pass' for result in results))


if __name__ == '__main__':
    raise SystemExit(main())
