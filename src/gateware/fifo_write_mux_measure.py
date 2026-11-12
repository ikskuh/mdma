#!/usr/bin/env python3
"""Measure the five-bus FIFO write mux on ECP5."""
import argparse
import json
from pathlib import Path

from alu.measure import ROOT, build_isolated, build_status, instantiate_ports, path_diagnostics, synth_module
from selector_measure import audit_capture_lanes, mapped_logic
from source_selector_measure import audit_launch


ROUTE_OPTIONS = ('--router', 'router1', '--no-tmdriv', '--placer-heap-beta', '0.5')


class WriteMux:
    name = 'fifo-write-mux'
    rtl = [Path(__file__).resolve().with_name('mdma_fifo_write_mux.v')]
    inputs = [('i_source_data', 320), ('i_source_ready', 5), ('i_source_id', 192), ('i_sink_done', 64)]
    outputs = [('o_sink_data', 4096), ('o_sink_ready', 64), ('o_sink_done', 64)]

    def instantiate(self, _mode, _clock, input_bus, output_bus, _config):
        return instantiate_ports(self, 'mdma_fifo_write_mux', [], None, input_bus, output_bus)


def render_report(result):
    rows = ['# Isolated ECP5 FIFO write mux', '',
            f"Initial baseline for LFE5UM5G-85F-8BG381, seed {result['seed']}.",
            f"nextpnr options `{' '.join(result['route_options'])}`.",
            'Routed totals include the pin-driven scan fixture.', '',
            '| Metric | Baseline |', '| --- | ---: |']
    for label, key in (
        ('Mux Fmax (MHz)', 'fmax_mhz'), ('Scan Fmax (MHz)', 'scan_fmax_mhz'),
        ('Synthesis (s)', 'synth_seconds'), ('Placement and routing (s)', 'route_seconds'),
        ('Yosys LUT4s, total', 'synth_lut4'), ('Yosys LUT4s, mux cone', 'mux_lut4'),
        ('Unique wires in final nextpnr ROUTING attributes', 'routed_wires'),
    ):
        rows.append(f'| {label} | {result.get(key, "—")} |')
    rows.append(f'| Build | {build_status(result)} |')
    capacity = result.get('resource_capacity', {})
    rows.extend(['', '| nextpnr resource | Used | Available | Utilization |', '| --- | ---: | ---: | ---: |'])
    for resource, used in sorted(result.get('resources', {}).items()):
        if used:
            total = capacity[resource]
            rows.append(f'| {resource} | {used:,} | {total:,} | {100*used/total:.2f}% |')
    return '\n'.join(rows + path_diagnostics([result])) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/rtl/fifo-write-mux')
    parser.add_argument('--timeout', type=int, default=900)
    parser.add_argument('--seed', type=int, default=3)
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error('timeout must be positive')

    unit = WriteMux()
    mode = 'bus'
    output = args.output.resolve()
    result = {'unit': unit.name, 'mode': mode, 'seed': args.seed, 'route_options': ROUTE_OPTIONS}
    build_isolated(unit, mode, output, args.timeout, result,
                   capture_lanes=(64, 64), indexed_readback=True, count_wires=True, route_options=ROUTE_OPTIONS)
    if 'synthesis_resources' in result:
        result['synth_lut4'] = result['synthesis_resources'].get('LUT4', 0)
        try:
            module = synth_module(output / unit.name / mode)
            input_bits = sum(width for _, width in unit.inputs)
            audit_launch(module, input_bits, enable_count=64)
            capture = audit_capture_lanes(module, input_bits, 64, 64)
            if len(capture) != sum(width for _, width in unit.outputs) or len(set(capture)) != len(capture):
                raise ValueError('synthesis merged independent mux outputs')
            _, cells = mapped_logic(module, capture, require_all_inputs=True)
            result['mux_resources'] = cells
            result['mux_lut4'] = cells.get('LUT4', 0)
        except ValueError as error:
            result['mapping_failure'] = str(error)

    (output / 'report.json').write_text(json.dumps(result, indent=2) + '\n')
    report = output / 'report.md'
    report.write_text(render_report(result))
    print(report.read_text(), end='')
    print(report)
    return int(build_status(result) != 'pass')


if __name__ == '__main__':
    raise SystemExit(main())
