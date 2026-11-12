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
DIVIDERS = {'DIV', 'DIVS'}
MATH = {'MUL', 'MULS'} | DIVIDERS
MIN_MHZ = 75.0


@dataclass(frozen=True)
class Divider:
    cuts: tuple[int, ...]
    sign_input: bool = False
    limb_bits: int = 0

    @property
    def latency(self):
        return len(self.cuts) + self.sign_input

    @property
    def parameters(self):
        mask = sum(1 << (step - 1) for step in self.cuts)
        return [f".CUTS(64'h{mask:016x})", f'.SIGN_INPUT({int(self.sign_input)})',
                f'.LIMB_BITS({self.limb_bits})']


def divider_defaults(family):
    defines = dict(line.split()[1:] for line in (HERE / 'mdma_div_config.vh').read_text().splitlines()
                   if line.startswith('`define '))
    prefix = f'MDMA_{family}_'
    mask = int(defines[prefix + 'CUTS'].removeprefix("64'h").replace('_', ''), 16)
    cuts = tuple(bit + 1 for bit in range(64) if mask & (1 << bit))
    return (Divider(cuts, bool(int(defines[prefix + 'SIGN_INPUT'])),
                    int(defines[prefix + 'LIMB_BITS'])), int(defines[prefix + 'SEED']))


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
        files = ['mdma_alu_result.v', 'mdma_typed_lanes.v', self.module + '.v']
        if self.family in DIVIDERS:
            files.append('mdma_div_pipeline.v')
        return [HERE / name for name in files]

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

    def instantiate(self, mode, clock, input_bus, output_bus, divider=None):
        if self.family in DIVIDERS:
            index = ('passthrough', 'registered', 'pipelined').index(mode)
            params = [f'.IMPLEMENTATION({index})']
            if divider is not None:
                params.extend(divider.parameters)
        else:
            params = [f'.REGISTERED({int(mode == "registered")})']
        if self.family in MATH:
            params.append(f'.SIGNED_OP({int(self.family.endswith("S"))})')
        return instantiate_ports(self, self.module, params, clock, input_bus, output_bus)


def instantiate_ports(unit, module, params, clock, input_bus, output_bus):
    ports = [f'.clk({clock})'] if clock is not None else []
    for bus, fields in ((input_bus, unit.inputs), (output_bus, unit.outputs)):
        bit = 0
        for name, width in fields:
            expression = f'{bus}[{bit}]' if width == 1 else f'{bus}[{bit} +: {width}]'
            ports.append(f'.{name}({expression})')
            bit += width
    return f'{module} #({", ".join(params)}) fu (\n    ' + ',\n    '.join(ports) + '\n);'


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


def isolated_top(unit, mode, divider=None, *, capture_lanes=None):
    input_bits = sum(width for _, width in unit.inputs)
    output_bits = sum(width for _, width in unit.outputs)
    scan_bits = input_bits
    launch_input = 'scan_input'
    capture_type = 'reg'
    capture_statement = '        capture <= fu_output;'
    capture_process = ''
    if capture_lanes is not None:
        targets, width = capture_lanes
        scan_bits += targets
        launch_input = f'scan_input[0 +: {input_bits}]'
        capture_type = 'wire'
        capture_statement = ''
        capture_process = f'''
    // Use native enables and keep the measured cone on DI. Inferred flops
    // can absorb the selector's data-or-zero mux into their reset logic.
    for (genvar lane = 0; lane < {targets}; lane = lane + 1) begin : capture_receiver
        for (genvar bit_index = 0; bit_index <= {width}; bit_index = bit_index + 1) begin : capture_lane
            localparam INDEX = bit_index == {width} ? {targets*width}+lane : lane*{width}+bit_index;
            TRELLIS_FF #(.CEMUX("CE")) capture_bit (
                .CLK(fu_clk), .CE(scan_input[{input_bits}+lane]), .LSR(1'b0),
                .DI(fu_output[INDEX]), .Q(capture[INDEX])
            );
        end
    end
'''
    return f'''
module mdma_alu_measure (
    input wire fu_clk, scan_clk, scan_in, scan_load,
    output wire scan_out
);
    reg [{scan_bits-1}:0] scan_input;
    reg [{output_bits-1}:0] scan_output;
    (* keep *) reg [{input_bits-1}:0] launch;
    (* keep *) {capture_type} [{output_bits-1}:0] capture;
    wire [{output_bits-1}:0] fu_output;

    always @(posedge scan_clk) begin
        scan_input <= {{scan_input[{scan_bits-2}:0], scan_in}};
        scan_output <= scan_load ? capture : {{scan_output[{output_bits-2}:0], 1'b0}};
    end
    assign scan_out = scan_output[{output_bits-1}];

    always @(posedge fu_clk) begin
        launch <= {launch_input};
{capture_statement}
    end
{capture_process}
    {unit.instantiate(mode, 'fu_clk', 'launch', 'fu_output', divider)}
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


def build(unit, mode, output, timeout, divider=None, seed=1):
    if mode == 'pipelined' and divider is None:
        divider, _ = divider_defaults(unit.family)
    result = {'unit': unit.name, 'mode': mode, 'seed': seed}
    if divider is not None:
        result.update(cuts=divider.cuts, latency=divider.latency,
                      sign_input=divider.sign_input, limb_bits=divider.limb_bits)
    return build_isolated(unit, mode, output, timeout, result, divider, min_mhz=MIN_MHZ)


def synth_module(work):
    netlist = json.loads((work / 'netlist.json').read_text())
    return netlist['modules']['mdma_alu_measure']


def synth_cells(work):
    return synth_module(work)['cells']


def routed_wires(work):
    """Count unique physical wires from nextpnr wire/pip/strength triples."""
    netlist = json.loads((work / 'routed.json').read_text())
    wires = set()
    for module in netlist['modules'].values():
        for net in module['netnames'].values():
            route = net.get('attributes', {}).get('ROUTING', '').strip()
            if route:
                fields = route.split(';')
                if len(fields) % 3 != 0 or not all(fields[::3]):
                    raise ValueError('invalid nextpnr ROUTING triples')
                wires.update(fields[::3])
    if not wires:
        raise ValueError('nextpnr exported no routed wires')
    return len(wires)


def build_isolated(unit, mode, output, timeout, result, config=None, *, min_mhz=None,
                   capture_lanes=None, count_wires=False):
    work = output / unit.name / mode
    work.mkdir(parents=True, exist_ok=True)
    for filename in ('netlist.json', 'route.json', 'routed.json', 'design.config', 'design.bit'):
        (work / filename).unlink(missing_ok=True)
    (work / 'top.v').write_text(isolated_top(unit, mode, config, capture_lanes=capture_lanes))
    stages = [
        ('synth', ['yosys', '-Q', '-T', '-p',
                   f'read_verilog -sv -I"{HERE}" ' + ' '.join(f'"{path}"' for path in unit.rtl)
                   + ' top.v; synth_ecp5 -top mdma_alu_measure -json netlist.json']),
        ('route', ['nextpnr-ecp5', '--um5g-85k', '--package', 'CABGA381', '--speed', '8',
                   '--seed', str(result['seed']), '--freq', str(MIN_MHZ),
                   '--timing-allow-fail', '--lpf-allow-unconstrained',
                   '--json', 'netlist.json', '--report', 'route.json', '--textcfg', 'design.config',
                   *(['--write', 'routed.json'] if count_wires else [])]),
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
            counts = {}
            for cell in synth_cells(work).values():
                kind = cell['type']
                counts[kind] = counts.get(kind, 0) + 1
            result['synthesis_resources'] = counts
        if stage == 'route':
            report = json.loads((work / 'route.json').read_text())
            result['resources'] = {key: item['used'] for key, item in report['utilization'].items()}
            if count_wires:
                result['resource_capacity'] = {key: item['available'] for key, item in report['utilization'].items()}
                try:
                    result['routed_wires'] = routed_wires(work)
                except (OSError, ValueError) as error:
                    result['mapping_failure'] = f'could not count final routed wires ({error})'
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
            if min_mhz is not None and 'fmax_mhz' in result and result['fmax_mhz'] < min_mhz:
                result['timing_failure'] = f'below {min_mhz:.1f} MHz'
    if 'failure' not in result and not (work / 'design.bit').is_file():
        result['failure'] = {'stage': 'pack', 'reason': 'bitstream missing',
                             'log': str((work / 'pack.log').relative_to(output)), 'diagnostics': []}
    return result


def comparison(old, new):
    if old is None or new is None:
        return f'{old if old is not None else "—"} → {new if new is not None else "—"}'
    delta = new - old
    percent = f'{100 * delta / old:+.2f}%' if old else 'undefined'
    return f'{old:g} → {new:g} ({delta:+g}, {percent})'


def build_status(result):
    if 'failure' in result:
        return result['failure']['stage'] + ' failed'
    return result.get('timing_failure') or result.get('mapping_failure', 'pass')


def render_report(results):
    keys = sorted({key for result in results for key, used in result.get('resources', {}).items() if used})
    rows = ['# Isolated ECP5 ALU measurements', '',
            f'The default sweep requires {MIN_MHZ:.1f} MHz routed FU Fmax and a bitstream.',
            'Comparison cells give baseline → candidate (raw delta, percentage delta).',
            'The FU and scan clocks are reported separately. Resource counts include the harness.', '',
            '| Unit | Modes | Pipeline clocks | FU MHz | Scan MHz | Synthesis seconds | '
            + ' | '.join(keys) + ' | Build |',
            '| --- | --- | ---: | ---: | ---: | ---: | ' + ' | '.join(['---:'] * len(keys)) + ' | --- |']
    for unit in dict.fromkeys(row['unit'] for row in results):
        builds = {row['mode']: row for row in results if row['unit'] == unit}
        comparisons = [('registered', 'passthrough')] if 'pipelined' not in builds else [
            (baseline, 'pipelined') for baseline in ('passthrough', 'registered') if baseline in builds
        ] or [('pipelined',)]
        for modes in comparisons:
            rows.append(report_row(unit, modes, builds, keys))

    rows.extend(path_diagnostics(results))
    return '\n'.join(rows) + '\n'


def path_diagnostics(results):
    rows = ['', '## Critical paths and build diagnostics', '']
    for result in results:
        label = f"{result['unit']} {result['mode']} (seed {result['seed']})"
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
            diagnostics = ' / '.join(failure['diagnostics']) or failure['reason']
            rows.append(f"- {label} · {failure['stage']} failed · {diagnostics} · `{failure['log']}`")
        for key in ('timing_failure', 'mapping_failure'):
            if key in result:
                rows.append(f'- {label} · {result[key]}')
    return rows


def report_row(unit, modes, builds, keys):
    items = [builds[mode] for mode in modes]
    cells = [unit, ' → '.join(modes), str(items[-1].get('latency', '—'))]
    return '| ' + ' | '.join(cells + metric_cells(items, keys)) + ' |'


def metric_cells(items, keys, extra_metrics=()):

    def format_values(values):
        return comparison(*values) if len(values) == 2 else str(values[0]) if values[0] is not None else '—'

    cells = []
    for key in ('fmax_mhz', 'scan_fmax_mhz', 'synth_seconds', *extra_metrics):
        cells.append(format_values([round(item[key], 3) if key in item else None for item in items]))
    for key in keys:
        cells.append(format_values([item['resources'].get(key, 0) if 'resources' in item else None
                                    for item in items]))
    return cells + [' → '.join(map(build_status, items))]


def main():
    units = isa_units()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('units', nargs='*', metavar='UNIT')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/rtl/alu')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=300, help='seconds allowed per build stage')
    parser.add_argument('--include-divider-baselines', action='store_true')
    parser.add_argument('--seed', type=int)
    parser.add_argument('--cuts', help='comma-separated divider register positions ending in 64')
    parser.add_argument('--sign-input', action=argparse.BooleanOptionalAction)
    parser.add_argument('--limb-bits', type=int, choices=(0, 8, 12, 16))
    args = parser.parse_args()
    selected = list(dict.fromkeys(name.upper() for name in args.units)) or list(units)
    for name in selected:
        if name not in units:
            parser.error(f'unknown ALU instance {name}')
    if args.jobs < 1 or args.timeout < 1:
        parser.error('jobs and timeout must be positive')
    if args.cuts or args.sign_input is not None or args.limb_bits is not None:
        if set(selected) - DIVIDERS:
            parser.error('divider parameters require selecting DIV or DIVS')
    cuts = None
    if args.cuts:
        try:
            cuts = tuple(map(int, args.cuts.split(',')))
        except ValueError:
            parser.error('cuts must be integer bit positions')
        if cuts[-1] != 64 or tuple(sorted(set(cuts))) != cuts or cuts[0] < 1:
            parser.error('cuts must be increasing positions from 1 to 64 and end in 64')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    def measure(job):
        unit, mode = job
        divider, seed = None, 1
        if mode == 'pipelined':
            defaults, seed = divider_defaults(unit.family)
            if cuts or args.sign_input is not None or args.limb_bits is not None:
                divider = Divider(cuts or defaults.cuts,
                                  defaults.sign_input if args.sign_input is None else args.sign_input,
                                  defaults.limb_bits if args.limb_bits is None else args.limb_bits)
        elif unit.family in DIVIDERS:
            _, seed = divider_defaults(unit.family)
        result = build(unit, mode, output, args.timeout, divider,
                       seed if args.seed is None else args.seed)
        print(f'{unit.name} {mode} · {build_status(result)}', flush=True)
        return result

    jobs = []
    for name in selected:
        if name not in DIVIDERS or args.include_divider_baselines:
            jobs.extend((units[name], mode) for mode in ('registered', 'passthrough'))
        if name in DIVIDERS:
            jobs.append((units[name], 'pipelined'))
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(measure, jobs))
    (output / 'report.json').write_text(json.dumps(results, indent=2) + '\n')
    (output / 'report.md').write_text(render_report(results))
    print(output / 'report.md')
    return int(any(build_status(item) != 'pass' for item in results
                   if item['unit'] not in DIVIDERS or item['mode'] == 'pipelined'))


if __name__ == '__main__':
    raise SystemExit(main())
