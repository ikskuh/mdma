#!/usr/bin/env python3
"""Characterize the sink selector using the isolated ECP5 scan harness."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from functools import cache
from hashlib import sha256
from itertools import combinations
import json
from pathlib import Path

from alu.measure import (
    ROOT, build_isolated, build_status, instantiate_ports, metric_cells, path_diagnostics, synth_module,
)


MODES = ('bus', 'data-mux', 'select-mux')
DEFAULT_SHAPES = [(64, bits) for bits in (2, 4, 6)]


@dataclass(frozen=True)
class Selector:
    width: int
    select_bits: int

    @property
    def targets(self):
        return 1 << self.select_bits

    @property
    def name(self):
        return f'SELECTOR_{self.width}x{self.targets}'

    @property
    def rtl(self):
        return [Path(__file__).with_name('mdma_sink_selector.v').resolve()]

    @property
    def inputs(self):
        return [('i_data', self.width), ('i_address', self.select_bits)]

    @property
    def outputs(self):
        return [('o_data', self.targets * self.width), ('o_valid', self.targets)]

    def instantiate(self, mode, _clock, input_bus, output_bus, _config):
        params = [f'.IMPLEMENTATION({MODES.index(mode)})', f'.WIDTH({self.width})',
                  f'.SELECT_BITS({self.select_bits})']
        return instantiate_ports(self, 'mdma_sink_selector', params, None, input_bus, output_bus)


def measure(selector, mode, output, timeout, seed):
    result = {'unit': selector.name, 'mode': mode, 'seed': seed,
              'width': selector.width, 'targets': selector.targets}
    build_isolated(selector, mode, output, timeout, result,
                   capture_lanes=(selector.targets, selector.width))
    if 'synthesis_resources' in result:
        module = synth_module(output / selector.name / mode)
        try:
            capture_inputs = audit_capture(selector, module)
            fingerprint, cells = mapped_logic(module, capture_inputs)
            result.update(logic_fingerprint=fingerprint, selector_cells=cells,
                          capture_registers=len(capture_inputs))
        except ValueError as error:
            result['mapping_failure'] = str(error)
    print(f'{selector.name} {mode} · {build_status(result)}', flush=True)
    return result


def audit_capture(selector, module):
    return audit_capture_lanes(module, selector.width + selector.select_bits,
                               selector.targets, selector.width)


def audit_capture_lanes(module, launch_width, targets, width):
    nets = module['netnames']
    capture = nets['capture']['bits']
    enables = nets['scan_input']['bits'][launch_width:]
    clock = module['ports']['fu_clk']['bits']
    flops = {cell['connections']['Q'][0]: cell for cell in module['cells'].values()
             if cell['type'] == 'TRELLIS_FF'}
    data_count = targets * width
    if len(set(capture)) != data_count + targets or len(set(enables)) != targets:
        raise ValueError('synthesis merged independent receiver captures or enables')

    inputs = []
    for index, bit in enumerate(capture):
        target = index // width if index < data_count else index - data_count
        cell = flops.get(bit)
        if cell is None or cell['parameters'].get('CEMUX') != 'CE':
            raise ValueError(f'target {target} lost a dedicated capture flop with native enable')
        ports = cell['connections']
        if (ports.get('CE') != [enables[target]] or ports.get('CLK') != clock
                or ports.get('LSR') != ['0']):
            raise ValueError(f'target {target} capture has unexpected clock, enable, or reset logic')
        inputs.append(ports['DI'][0])
    return inputs


def mapped_logic(module, outputs, *, require_all_inputs=False):
    """Fingerprint the mapped selector cone, excluding scan and capture logic."""
    launch = {bit: index for index, bit in enumerate(module['netnames']['launch']['bits'])}
    drivers = {}
    for name, cell in module['cells'].items():
        for port, direction in cell['port_directions'].items():
            if direction == 'output':
                for bit in cell['connections'][port]:
                    drivers[bit] = (name, cell, port)

    used = set()
    used_inputs = set()

    @cache
    def fingerprint(bit):
        if bit in launch:
            used_inputs.add(bit)
            return f'input {launch[bit]}'
        if isinstance(bit, str):
            return f'constant {bit}'
        if bit not in drivers:
            raise ValueError(f'missing selector driver for bit {bit}')
        name, cell, output_port = drivers[bit]
        if cell['type'] == 'TRELLIS_FF':
            raise ValueError('selector cone includes a register outside the launch boundary')
        used.add(name)
        inputs = [(port, [fingerprint(wire) for wire in cell['connections'][port]])
                  for port, direction in sorted(cell['port_directions'].items()) if direction == 'input']
        logic = (cell['type'], cell['parameters'], output_port, inputs)
        return sha256(json.dumps(logic, sort_keys=True).encode()).hexdigest()

    signature = [fingerprint(bit) for bit in outputs]
    if require_all_inputs and len(used_inputs) != len(launch):
        raise ValueError(f'only {len(used_inputs)} of {len(launch)} launched bits reach the selector outputs')
    counts = {}
    for name in used:
        kind = module['cells'][name]['type']
        counts[kind] = counts.get(kind, 0) + 1
    digest = sha256(json.dumps((signature, counts), sort_keys=True).encode()).hexdigest()
    return digest, counts


def render_report(results, *, kind='sink', baseline='data-mux', physical_counts=False):
    keys = sorted({key for row in results for key, used in row.get('resources', {}).items() if used})
    metrics = ('synth_lut4', 'routed_wires') if physical_counts else ()
    extra = ' | Synth LUT4 | Routed wires' if physical_counts else ''
    rows = [f'# Isolated ECP5 {kind} selector measurements', '',
            'Timing is characterized without a frequency floor. Resource totals include the harness.',
            f'Comparisons give {baseline} baseline → candidate (raw delta, percentage delta).']
    if physical_counts:
        rows.append('LUT4 counts come from Yosys. Wire counts are unique wire names in nextpnr final '
                    'ROUTING attributes. Routed resource counts and capacities come from nextpnr.')
    rows.extend(['', '| Selector | Mode | FU MHz | Scan MHz | Synthesis seconds' + extra
                 + ' | ' + ' | '.join(keys) + ' | Build |',
                 '| --- | --- | ---: | ---: | ---: | '
                 + ' | '.join(['---:'] * (len(metrics) + len(keys))) + ' | --- |'])
    baselines = {row['unit']: row for row in results if row['mode'] == baseline}
    for result in results:
        unit, mode = result['unit'], result['mode']
        items = [result] if mode == baseline else [baselines[unit], result]
        label = mode if mode == baseline else f'{baseline} → {mode}'
        rows.append('| ' + ' | '.join([unit, label] + metric_cells(items, keys, metrics)) + ' |')
    if physical_counts:
        rows.extend(['', '## Device utilization', '', '| Selector | Mode | Resources |', '| --- | --- | --- |'])
        for result in results:
            capacities = result.get('resource_capacity', {})
            usage = ', '.join(f'{key} {count:,}/{capacities[key]:,} ({100*count/capacities[key]:.2f}%)'
                              for key, count in sorted(result.get('resources', {}).items())
                              if count and capacities.get(key))
            rows.append(f"| {result['unit']} | {result['mode']} | {usage} |")
    rows.extend(['', '## Mapped selector logic', '',
                 '| Selector | Mode | Cells in selector cone | Capture flops |',
                 '| --- | --- | --- | ---: |'])
    for result in results:
        if 'selector_cells' in result:
            cells = ', '.join(f'{kind} {count}' for kind, count in sorted(result['selector_cells'].items()))
            rows.append(f"| {result['unit']} | {result['mode']} | {cells} | {result['capture_registers']} |")
    for first, second in combinations(results, 2):
        if (first['unit'] == second['unit'] and 'logic_fingerprint' in first
                and first['logic_fingerprint'] == second.get('logic_fingerprint')):
            rows.extend(['', f"- {first['unit']} · {first['mode']} and {second['mode']} "
                              'have the same mapped selector fingerprint.'])
    return '\n'.join(rows + path_diagnostics(results)) + '\n'


def parse_shape(text):
    try:
        width, targets = map(int, text.lower().split('x'))
        if width >= 1 and targets >= 2 and targets & (targets - 1) == 0:
            return width, targets.bit_length() - 1
    except ValueError:
        pass
    raise argparse.ArgumentTypeError('use WIDTHxTARGETS with positive WIDTH and power-of-two TARGETS >= 2')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('shapes', type=parse_shape, nargs='*', metavar='WIDTHxTARGETS')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/rtl/selector')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--seed', type=int, default=1)
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout < 1:
        parser.error('jobs and timeout must be positive')
    output = args.output.resolve()
    shapes = dict.fromkeys(args.shapes or DEFAULT_SHAPES)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        jobs = [pool.submit(measure, Selector(*shape), mode, output, args.timeout, args.seed)
                for shape in shapes for mode in ('data-mux', 'bus', 'select-mux')]
        results = [job.result() for job in jobs]
    (output / 'report.json').write_text(json.dumps(results, indent=2) + '\n')
    report = output / 'report.md'
    report.write_text(render_report(results))
    print(report)
    return int(any(build_status(result) != 'pass' for result in results))


if __name__ == '__main__':
    raise SystemExit(main())
