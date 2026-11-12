#!/usr/bin/env python3
"""Measure each isolated ALU before and after adding four-entry FIFOs."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import json
from pathlib import Path

from measure import (
    DIVIDERS, HERE, ROOT, Unit, build_isolated, build_status, divider_defaults, isa_units,
    metric_cells, path_diagnostics, synth_cells,
)


@dataclass(frozen=True)
class BufferedUnit(Unit):
    @property
    def rtl(self):
        return [*super().rtl, HERE / 'mdma_alu_fifo_fixture.v', HERE.parent / 'mdma_fifo.v']

    def instantiate(self, mode, clock, input_bus, output_bus, divider=None):
        inputs = sum(width for _, width in self.inputs)
        outputs = sum(width for _, width in self.outputs)
        return f"""
    wire [{inputs-1}:0] fu_inputs;
    wire [{outputs-1}:0] fu_results;
    mdma_alu_fifo_fixture #(.SINKS({len(self.sinks)}), .SOURCES({len(self.sources)})) fu_queues (
        .clk({clock}), .drive({input_bus}), .observed({output_bus}),
        .alu_inputs(fu_inputs), .alu_outputs(fu_results)
    );
    {super().instantiate(mode, clock, 'fu_inputs', 'fu_results', divider)}
"""


def measure(unit, mode, output, timeout, buffered):
    divider, seed = divider_defaults(unit.family) if unit.family in DIVIDERS else (None, 1)
    variant = 'buffered' if buffered else 'direct'
    if buffered:
        unit = BufferedUnit(unit.name, unit.family, unit.sinks, unit.sources)
    result = {'unit': unit.name, 'mode': mode, 'seed': seed, 'variant': variant}
    build_isolated(unit, mode, output / variant, timeout, result,
                   divider if mode == 'pipelined' else None, count_wires=True)
    if 'failure' in result:
        result['failure']['log'] = f"{variant}/{result['failure']['log']}"
    if 'synthesis_resources' in result:
        result['synth_lut4'] = result['synthesis_resources'].get('LUT4', 0)
        if buffered:
            audit_fifos(unit, output / variant / unit.name / mode, result)
    print(f'{unit.name} {mode} {variant} · {build_status(result)}', flush=True)
    return result


def audit_fifos(unit, work, result):
    names = ['fu_queues.output_fifo',
             *(f'fu_queues.operands[{lane}].input_fifo' for lane in range(len(unit.sinks)))]
    lutram = [name for name, cell in synth_cells(work).items() if cell['type'] == 'TRELLIS_DPR16X4']
    missing = [name for name in names if not any(cell.startswith(name + '.') for cell in lutram)]
    if missing:
        result['mapping_failure'] = 'FIFO payload did not infer LUT RAM: ' + ', '.join(missing)


def render_report(pairs):
    results = [item for pair in pairs for item in pair]
    keys = sorted({key for result in results for key, used in result.get('resources', {}).items() if used})
    rows = ['# Isolated ECP5 ALUs with four-entry FIFOs', '',
            'Cells give direct → buffered (raw delta, percentage delta). Routed Fmax is characterized.',
            'LUT4s come from Yosys. Wires are unique physical wire names in nextpnr final ROUTING attributes.',
            'Resource counts include the matching scan harness.', '',
            '| ALU | Mode | FU MHz | Scan MHz | Synthesis seconds | Synth LUT4 | Routed wires | '
            + ' | '.join(keys) + ' | Build |',
            '| --- | --- | ' + ' | '.join(['---:'] * (5 + len(keys))) + ' | --- |']
    for direct, buffered in pairs:
        cells = [direct['unit'], direct['mode']]
        cells.extend(metric_cells([direct, buffered], keys, ('synth_lut4', 'routed_wires')))
        rows.append('| ' + ' | '.join(cells) + ' |')

    rows.extend(['', '## Device utilization', '', '| ALU | Mode | Variant | Resources |',
                 '| --- | --- | --- | --- |'])
    for result in results:
        capacity = result.get('resource_capacity', {})
        usage = ', '.join(f'{key} {used:,}/{capacity[key]:,} ({100*used/capacity[key]:.2f}%)'
                          for key, used in sorted(result.get('resources', {}).items())
                          if used and capacity.get(key))
        rows.append(f"| {result['unit']} | {result['mode']} | {result['variant']} | {usage} |")

    diagnostics = [dict(row, mode=f"{row['mode']} {row['variant']}") for row in results]
    return '\n'.join(rows + path_diagnostics(diagnostics)) + '\n'


def main():
    units = isa_units()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('units', nargs='*', metavar='UNIT')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/rtl/alu-integration')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=420)
    parser.add_argument('--include-divider-baselines', action='store_true')
    args = parser.parse_args()
    selected = list(dict.fromkeys(name.upper() for name in args.units)) or list(units)
    if set(selected) - units.keys():
        parser.error(f"unknown ALU instances: {', '.join(sorted(set(selected) - units.keys()))}")
    if args.jobs < 1 or args.timeout < 1:
        parser.error('jobs and timeout must be positive')
    output = args.output.resolve()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        jobs = []
        for name in selected:
            unit = units[name]
            modes = ['registered', 'passthrough']
            if unit.family in DIVIDERS:
                modes = [*modes, 'pipelined'] if args.include_divider_baselines else ['pipelined']
            for mode in modes:
                jobs.append([pool.submit(measure, unit, mode, output, args.timeout, buffered)
                             for buffered in (False, True)])
        pairs = [[job.result() for job in pair] for pair in jobs]
    (output / 'report.json').write_text(json.dumps(pairs, indent=2) + '\n')
    report = output / 'report.md'
    report.write_text(render_report(pairs))
    print(report)
    return int(any(build_status(row) != 'pass' for pair in pairs for row in pair))


if __name__ == '__main__':
    raise SystemExit(main())
