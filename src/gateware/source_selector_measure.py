#!/usr/bin/env python3
"""Characterize source selectors using the isolated ECP5 scan harness."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import json
from pathlib import Path

from alu.measure import ROOT, build_isolated, build_status, instantiate_ports, synth_module
from selector_measure import DEFAULT_SHAPES, audit_capture_lanes, mapped_logic, parse_shape, render_report


MODES = ('classic-mux', 'or-mux', 'or-address')


@dataclass(frozen=True)
class SourceSelector:
    width: int
    select_bits: int

    @property
    def sources(self):
        return 1 << self.select_bits

    @property
    def name(self):
        return f'SOURCE_SELECTOR_{self.width}x{self.sources}'

    @property
    def rtl(self):
        return [Path(__file__).with_name('mdma_source_selector.v').resolve()]

    @property
    def inputs(self):
        return [('i_data', self.width * self.sources), ('i_valid', self.sources),
                ('i_address', self.select_bits)]

    @property
    def outputs(self):
        return [('o_data', self.width), ('o_valid', 1)]

    def instantiate(self, mode, _clock, input_bus, output_bus, _config):
        params = [f'.IMPLEMENTATION({MODES.index(mode)})', f'.WIDTH({self.width})',
                  f'.SELECT_BITS({self.select_bits})']
        return instantiate_ports(self, 'mdma_source_selector', params, None, input_bus, output_bus)


def audit_launch(module, width):
    nets = module['netnames']
    launch = nets['launch']['bits']
    scan = nets['scan_input']['bits']
    clock = module['ports']['fu_clk']['bits']
    flops = {cell['connections']['Q'][0]: cell['connections'] for cell in module['cells'].values()
             if cell['type'] == 'TRELLIS_FF'}
    if len(launch) != width or len(set(launch)) != width or len(set(scan)) != width + 1:
        raise ValueError('synthesis merged independent source launch or scan lanes')
    for index, bit in enumerate(launch):
        ports = flops.get(bit, {})
        if ports.get('DI') != [scan[index]] or ports.get('CLK') != clock or ports.get('LSR') != ['0']:
            raise ValueError(f'launch lane {index} lost its dedicated scan-fed flop')


def measure(selector, mode, output, timeout, seed):
    result = {'unit': selector.name, 'mode': mode, 'seed': seed,
              'width': selector.width, 'sources': selector.sources}
    build_isolated(selector, mode, output, timeout, result,
                   capture_lanes=(1, selector.width), count_wires=True)
    if 'synthesis_resources' in result:
        result['synth_lut4'] = result['synthesis_resources'].get('LUT4', 0)
        module = synth_module(output / selector.name / mode)
        try:
            launch_width = sum(width for _, width in selector.inputs)
            audit_launch(module, launch_width)
            inputs = audit_capture_lanes(module, launch_width, 1, selector.width)
            fingerprint, cells = mapped_logic(module, inputs, require_all_inputs=True)
            result.update(logic_fingerprint=fingerprint, selector_cells=cells,
                          launch_registers=launch_width, capture_registers=len(inputs))
        except ValueError as error:
            result['mapping_failure'] = str(error)
    print(f'{selector.name} {mode} · {build_status(result)}', flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('shapes', type=parse_shape, nargs='*', metavar='WIDTHxSOURCES')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/rtl/source-selector')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=420)
    parser.add_argument('--seed', type=int, default=1)
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout < 1:
        parser.error('jobs and timeout must be positive')
    output = args.output.resolve()
    shapes = dict.fromkeys(args.shapes or DEFAULT_SHAPES)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        jobs = [pool.submit(measure, SourceSelector(*shape), mode, output, args.timeout, args.seed)
                for shape in shapes for mode in MODES]
        results = [job.result() for job in jobs]
    (output / 'report.json').write_text(json.dumps(results, indent=2) + '\n')
    report = output / 'report.md'
    report.write_text(render_report(results, kind='source', baseline=MODES[0], physical_counts=True))
    print(report)
    return int(any(build_status(result) != 'pass' for result in results))


if __name__ == '__main__':
    raise SystemExit(main())
