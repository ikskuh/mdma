#!/usr/bin/env python3
"""Build the 64-way selector integration fixtures."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from itertools import product
import json
from pathlib import Path

from alu.measure import (
    ROOT, build_isolated, build_status, instantiate_ports, metric_cells, path_diagnostics, synth_module,
)
from selector_measure import MODES as SINK_MODES, audit_capture_lanes
from source_selector_measure import MODES as SOURCE_MODES, audit_launch


CHAINS = ('uop', 'fifo', 'fifo-uop-fifo')


@dataclass(frozen=True)
class Chain:
    name: str

    @property
    def active_sources(self):
        return 1 if self.name == 'fifo' else 3

    @property
    def rtl(self):
        path = Path(__file__).resolve().parent
        return [*(path / f'mdma_{name}.v' for name in
                  ('selector_chain_fixture', 'sink_selector', 'source_selector', 'fifo')),
                *(path / 'alu' / f'mdma_{name}.v' for name in ('uop', 'alu_fifo_fixture', 'alu_result'))]

    @property
    def inputs(self):
        other = 64 - self.active_sources
        return [('reset', 1), ('i_data', 64), ('i_valid', 1), ('i_sink_address', 6),
                ('i_source_address', 6), ('i_take', 1), ('i_other_sink_ready', 63),
                ('i_other_source_data', 64 * other), ('i_other_source_valid', other)]

    @property
    def outputs(self):
        return [('o_sink_data', 4096), ('o_sink_valid', 64), ('o_input_take', 1),
                ('o_data', 64), ('o_valid', 1), ('o_source_take', 64)]

    def instantiate(self, _mode, clock, input_bus, output_bus, case):
        params = [f'.{key}({value})' for key, value in case.parameters.items()]
        return instantiate_ports(self, 'mdma_selector_chain_fixture', params, clock, input_bus, output_bus)


@dataclass(frozen=True)
class Case:
    chain: str
    sink: str
    source: str
    registered: bool | None
    bypass: bool | None

    @property
    def parameters(self):
        return dict(CHAIN=CHAINS.index(self.chain), SINK_MODE=SINK_MODES.index(self.sink),
                    SOURCE_MODE=SOURCE_MODES.index(self.source),
                    REGISTERED=int(self.registered is not False), BYPASS=int(self.bypass is not False))

    @property
    def mode(self):
        fields = [self.sink, self.source]
        if self.registered is not None:
            fields.append('registered' if self.registered else 'passthrough')
        if self.bypass is not None:
            fields.append('bypass-on' if self.bypass else 'bypass-off')
        return '-'.join(fields)

    @property
    def baseline(self):
        return Case(self.chain, SINK_MODES[0], SOURCE_MODES[0],
                    True if self.registered is not None else None,
                    True if self.bypass is not None else None).mode


def cases():
    for chain in CHAINS:
        registered = (None,) if chain == 'fifo' else (True, False)
        bypass = (None,) if chain == 'uop' else (True, False)
        for sink, source, reg, bypassed in product(SINK_MODES, SOURCE_MODES, registered, bypass):
            yield Case(chain, sink, source, reg, bypassed)


def audit_endpoints(chain, module):
    inputs = sum(width for _, width in chain.inputs)
    audit_launch(module, inputs, enable_count=64)
    audit_capture_lanes(module, inputs, 64, 64)
    # Every independent launched bit must reach at least one mapped input.
    sinks = {bit for cell in module['cells'].values()
             for port, direction in cell['port_directions'].items() if direction == 'input'
             for bit in cell['connections'][port]}
    missing = set(module['netnames']['launch']['bits']) - sinks
    if missing:
        raise ValueError(f'{len(missing)} launched fixture bits have no mapped load')


def limiting_path(critical_path):
    steps = critical_path['path']
    end = steps[-1]['to']['cell']
    signals = [step.get('net', '') for step in steps]
    if end.startswith('capture_receiver'):
        return 'sink selector endpoint'
    if any('take' in name or '.used' in name for name in signals):
        return 'handshake/backpressure'
    if any('uop_path' in name or 'fifo_path' in name for name in signals):
        return 'active chain'
    return 'source selector endpoint'


def measure(case, output, timeout, seed):
    unit = Chain(case.chain)
    result = {'unit': unit.name, 'mode': case.mode, 'seed': seed, 'baseline': case.baseline}
    build_isolated(unit, case.mode, output, timeout, result, case,
                   capture_lanes=(64, 64), count_wires=True, indexed_readback=True)
    if 'synthesis_resources' in result:
        result['synth_lut4'] = result['synthesis_resources'].get('LUT4', 0)
        try:
            audit_endpoints(unit, synth_module(output / unit.name / case.mode))
        except ValueError as error:
            result['mapping_failure'] = str(error)
    if 'critical_path' in result:
        result['limiting_path'] = limiting_path(result['critical_path'])
    work = output / unit.name / case.mode
    (work / 'metrics.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'{unit.name} {case.mode} · {build_status(result)}', flush=True)
    return result


def render_report(results):
    keys = sorted({key for result in results for key, value in result.get('resources', {}).items() if value})
    lookup = {(r['unit'], r['mode']): r for r in results}
    rows = ['# Isolated ECP5 selector chains', '',
            'Fmax is characterized. Deltas use the shared-bus sink and classic-mux source, '
            'with registered UOP and full-FIFO replacement where present.',
            'LUT4s come from Yosys and unique wires from nextpnr final ROUTING attributes. '
            'Totals include the pin-driven fixture.', '',
            '| Chain | Configuration | Limiting path | FU MHz | Scan MHz | Synthesis seconds | LUT4 | Wires | '
            + ' | '.join(keys) + ' | Build |',
            '| --- | --- | --- | ' + ' | '.join(['---:'] * (5 + len(keys))) + ' | --- |']
    for result in results:
        baseline = lookup.get((result['unit'], result['baseline']))
        items = [baseline, result] if baseline and baseline != result else [result]
        cells = [result['unit'], result['mode'], result.get('limiting_path', '—')]
        rows.append('| ' + ' | '.join(cells + metric_cells(items, keys, ('synth_lut4', 'routed_wires'))) + ' |')

    rows.extend(['', '## Device utilization', '', '| Chain | Configuration | Resources |', '| --- | --- | --- |'])
    for result in results:
        cap = result.get('resource_capacity', {})
        usage = ', '.join(f'{key} {n:,}/{cap[key]:,} ({100*n/cap[key]:.2f}%)'
                          for key, n in sorted(result.get('resources', {}).items()) if n and cap.get(key))
        rows.append(f"| {result['unit']} | {result['mode']} | {usage} |")
    return '\n'.join(rows + path_diagnostics(results)) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/rtl/selector-chains')
    parser.add_argument('--chain', choices=CHAINS)
    parser.add_argument('--sink', choices=SINK_MODES)
    parser.add_argument('--source', choices=SOURCE_MODES)
    parser.add_argument('--jobs', type=int, default=8)
    parser.add_argument('--timeout', type=int, default=480)
    parser.add_argument('--seed', type=int, default=1)
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout < 1:
        parser.error('jobs and timeout must be positive')
    output = args.output.resolve()
    selected = [case for case in cases() if (args.chain is None or case.chain == args.chain)
                and (args.sink is None or case.sink == args.sink)
                and (args.source is None or case.source == args.source)]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        jobs = [pool.submit(measure, case, output, args.timeout, args.seed) for case in selected]
        results = [job.result() for job in jobs]
    (output / 'report.json').write_text(json.dumps(results, indent=2) + '\n')
    report = output / 'report.md'
    report.write_text(render_report(results))
    print(report)
    return int(any(build_status(result) != 'pass' for result in results))


if __name__ == '__main__':
    raise SystemExit(main())
