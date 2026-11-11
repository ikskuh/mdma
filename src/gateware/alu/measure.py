#!/usr/bin/env python3
"""Build isolated MDMA ALUs and report their routed ECP5 measurements."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import json
from pathlib import Path
import subprocess
import sys
from time import monotonic

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / 'src/pylibs'))
from mdma import SINK_BY_INDEX


FAMILIES = {
    'ARITH', 'LOGIC', 'SHIFT', 'CMP', 'MASK', 'UOP', 'BITCNT', 'SEL', 'PACK',
    'UNPACK', 'SWIZZLE8', 'MUL', 'MULS', 'DIV', 'DIVS',
}
MATH = {'MUL', 'MULS', 'DIV', 'DIVS'}


@dataclass(frozen=True)
class Unit:
    name: str
    family: str
    sinks: tuple[str, ...]
    sources: tuple[str, ...]

    @property
    def module(self):
        family = self.family.removesuffix('S') if self.family in MATH else self.family
        return 'mdma_' + family.lower()

    @property
    def rtl(self):
        return [HERE / name for name in ('mdma_alu_result.v', 'mdma_typed_lanes.v', self.module + '.v')]

    @property
    def inputs(self):
        ports = [('reset', 1)]
        for sink in self.sinks:
            ports.extend([(f'i_{sink}_data', 64), (f'i_{sink}_valid', 1)])
        return ports + [(f'o_{source}_take', 1) for source in self.sources]

    @property
    def outputs(self):
        ports = [(f'i_{sink}_take', 1) for sink in self.sinks]
        for source in self.sources:
            ports.extend([(f'o_{source}_data', 64), (f'o_{source}_valid', 1)])
        return ports

    def instantiate(self, registered, clock, input_bus, output_bus):
        params = [f'.REGISTERED({int(registered)})']
        if self.family in MATH:
            params.append(f'.SIGNED_OP({int(self.family.endswith("S"))})')
        ports = [f'.clk({clock})']
        for bus, fields in ((input_bus, self.inputs), (output_bus, self.outputs)):
            bit = 0
            for name, width in fields:
                expression = f'{bus}[{bit}]' if width == 1 else f'{bus}[{bit} +: {width}]'
                ports.append(f'.{name}({expression})')
                bit += width
        return f'{self.module} #({", ".join(params)}) fu (\n    ' + ',\n    '.join(ports) + '\n);'


def isa_units():
    instances = dict.fromkeys(info.unit for info in SINK_BY_INDEX.values()
                              if info.unit.unit.name in FAMILIES)
    units = {}
    for instance in instances:
        family = instance.unit.name
        sources = tuple(name.lower() for name in instance.unit.sources)
        if family in {'PACK', 'UNPACK', 'DIV', 'DIVS'}:
            sources += ('fault',)
        name = str(instance)
        units[name] = Unit(name, family, tuple(name.lower() for name in instance.unit.sinks), sources)
    return units


def isolated_top(unit, registered):
    input_bits = sum(width for _, width in unit.inputs)
    output_bits = sum(width for _, width in unit.outputs)
    return f'''
module mdma_alu_measure (
    input wire fu_clk, scan_clk, scan_in, scan_load,
    output wire scan_out
);
    reg [{input_bits-1}:0] scan_input;
    reg [{output_bits-1}:0] scan_output;
    (* keep *) reg [{input_bits-1}:0] launch;
    (* keep *) reg [{output_bits-1}:0] capture;
    wire [{output_bits-1}:0] fu_output;

    always @(posedge scan_clk) begin
        scan_input <= {{scan_input[{input_bits-2}:0], scan_in}};
        scan_output <= scan_load ? capture : {{scan_output[{output_bits-2}:0], 1'b0}};
    end
    assign scan_out = scan_output[{output_bits-1}];

    always @(posedge fu_clk) begin
        launch <= scan_input;
        capture <= fu_output;
    end

    {unit.instantiate(registered, 'fu_clk', 'launch', 'fu_output')}
endmodule
'''


def run_stage(work, name, command, timeout):
    start = monotonic()
    with (work / f'{name}.log').open('w') as log:
        try:
            subprocess.run(command, cwd=work, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=timeout)
        except (OSError, subprocess.SubprocessError) as error:
            print(error, file=log)
            return round(monotonic() - start, 3), str(error)
    return round(monotonic() - start, 3), None


def clock_path(report, clock):
    return max((path for path in report['critical_paths']
                if path['from'] == path['to'] == f'posedge {clock}'),
               key=lambda path: sum(step['delay'] for step in path['path']), default=None)


def in_fu_boundary(path):
    cells = {step[endpoint]['cell'] for step in path['path'] for endpoint in ('from', 'to')}
    # The packer inserts feed-through cells for FU carry chains.
    prefixes = ('launch_', 'capture_', 'fu.', 'fu_output_', '$nextpnr_CCU2C_')
    return all(cell.startswith(prefixes) for cell in cells)


def build(unit, mode, output, timeout):
    work = output / unit.name / mode
    work.mkdir(parents=True, exist_ok=True)
    for filename in ('netlist.json', 'route.json', 'design.config', 'design.bit'):
        (work / filename).unlink(missing_ok=True)
    (work / 'top.v').write_text(isolated_top(unit, mode == 'registered'))
    result = {'unit': unit.name, 'mode': mode}
    stages = [
        ('synth', ['yosys', '-Q', '-T', '-p',
                   'read_verilog -sv ' + ' '.join(f'"{path}"' for path in unit.rtl)
                   + ' top.v; synth_ecp5 -top mdma_alu_measure -json netlist.json']),
        ('route', ['nextpnr-ecp5', '--um5g-85k', '--package', 'CABGA381', '--speed', '8',
                   '--seed', '1', '--timing-allow-fail', '--lpf-allow-unconstrained',
                   '--json', 'netlist.json', '--report', 'route.json', '--textcfg', 'design.config']),
        ('pack', ['ecppack', 'design.config', 'design.bit']),
    ]
    for stage, command in stages:
        seconds, error = run_stage(work, stage, command, timeout)
        result[f'{stage}_seconds'] = seconds
        if error:
            log = work / f'{stage}.log'
            with log.open() as stream:
                diagnostics = [line.strip() for line in stream if 'error:' in line.lower()
                               or 'failed' in line.lower()]
            result['failure'] = {'stage': stage, 'reason': error, 'log': str(log.relative_to(output)),
                                 'diagnostics': diagnostics[-4:]}
            break
        if stage == 'synth':
            netlist = json.loads((work / 'netlist.json').read_text())
            counts = {}
            for cell in netlist['modules']['mdma_alu_measure']['cells'].values():
                kind = cell['type']
                counts[kind] = counts.get(kind, 0) + 1
            result['synthesis_resources'] = counts
        if stage == 'route':
            report = json.loads((work / 'route.json').read_text())
            result['resources'] = {key: item['used'] for key, item in report['utilization'].items()}
            for clock, timing in report['fmax'].items():
                if 'scan_clk' in clock:
                    result['scan_fmax_mhz'] = timing['achieved']
                if 'fu_clk' in clock:
                    path = clock_path(report, clock)
                    if path:
                        result['critical_path'] = path
                    if path and in_fu_boundary(path):
                        result['fmax_mhz'] = timing['achieved']
                    else:
                        result['timing_failure'] = 'critical path outside the FU timing boundary'
            if 'fmax_mhz' not in result:
                result.setdefault('timing_failure', 'missing FU clock timing')
            if 'scan_fmax_mhz' not in result:
                result.setdefault('timing_failure', 'missing scan clock timing')
    return result


def comparison(old, new):
    if old is None or new is None:
        return f'{old if old is not None else "—"} → {new if new is not None else "—"}'
    delta = new - old
    percent = f'{100 * delta / old:+.2f}%' if old else 'undefined'
    return f'{old:g} → {new:g} ({delta:+g}, {percent})'


def render_report(results):
    keys = sorted({key for result in results for key, used in result.get('resources', {}).items() if used})
    rows = ['# Isolated ECP5 ALU measurements', '',
            'Each cell gives registered → passthrough (raw delta, percentage delta).',
            'The FU and scan clocks are reported separately. Resource counts include the harness.', '',
            '| Unit | FU MHz | Scan MHz | Synthesis seconds | ' + ' | '.join(keys) + ' | Build |',
            '| --- | ---: | ---: | ---: | ' + ' | '.join(['---:'] * len(keys)) + ' | --- |']
    for index in range(0, len(results), 2):
        reg, bypass = results[index:index+2]
        cells = [reg['unit']]
        for key in ('fmax_mhz', 'scan_fmax_mhz', 'synth_seconds'):
            cells.append(comparison(*(round(item[key], 3) if key in item else None for item in (reg, bypass))))
        for key in keys:
            cells.append(comparison(*(item['resources'].get(key, 0) if 'resources' in item else None
                                      for item in (reg, bypass))))
        statuses = []
        for item in (reg, bypass):
            if 'failure' in item:
                statuses.append(item['failure']['stage'] + ' failed')
            elif 'timing_failure' in item:
                statuses.append(item['timing_failure'])
            else:
                statuses.append('bitstream')
        rows.append('| ' + ' | '.join(cells + [' → '.join(statuses)]) + ' |')

    rows.extend(['', '## Critical paths and build diagnostics', ''])
    for result in results:
        label = f"{result['unit']} {result['mode']}"
        if 'critical_path' in result:
            steps = result['critical_path']['path']
            first = steps[0]['from']['cell']
            last = steps[-1]['to']['cell']
            delay = sum(step['delay'] for step in steps)
            routing = sum(step['delay'] for step in steps if step['type'] == 'routing')
            logic = sum(step['type'] == 'logic' for step in steps)
            rows.append(f'- {label} · {delay:.2f} ns, {routing:.2f} ns routing, '
                        f'{logic} logic arcs · `{first}` → `{last}`')
        if 'failure' in result:
            failure = result['failure']
            diagnostics = '; '.join(failure['diagnostics']) or failure['reason']
            rows.append(f"- {label} · {failure['stage']} failed · {diagnostics} · `{failure['log']}`")
    return '\n'.join(rows) + '\n'


def main():
    units = isa_units()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('units', nargs='*', metavar='UNIT')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/rtl/alu')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=300, help='seconds allowed per build stage')
    args = parser.parse_args()
    selected = list(dict.fromkeys(name.upper() for name in args.units)) or list(units)
    for name in selected:
        if name not in units:
            parser.error(f'unknown ALU instance {name}')
    if args.jobs < 1 or args.timeout < 1:
        parser.error('jobs and timeout must be positive')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    def measure(job):
        unit, mode = job
        result = build(unit, mode, output, args.timeout)
        status = result.get('failure', {}).get('stage') or result.get('timing_failure')
        print(f'{unit.name} {mode} · {status or "bitstream generated"}', flush=True)
        return result

    jobs = [(units[name], mode) for name in selected for mode in ('registered', 'passthrough')]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(measure, jobs))
    (output / 'report.json').write_text(json.dumps(results, indent=2) + '\n')
    (output / 'report.md').write_text(render_report(results))
    print(output / 'report.md')
    return int(any('timing_failure' in item or ('failure' in item and units[item['unit']].family not in MATH)
                   for item in results))


if __name__ == '__main__':
    raise SystemExit(main())
