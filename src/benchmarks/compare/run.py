"""Build and benchmark the RISC-V CPU variants on the ECP5 SoC."""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
COREMARK_PORT = ROOT / 'src/qbe/coremark'
COREMARK_UPSTREAM = ROOT / 'vendor/coremark'

EXAMPLES = ROOT / 'examples/qbe'
EXPECTED = {'sum_to': 55, 'mix_loop': 0x41090bb9}
SOURCES = {path.stem: path for path in sorted(EXAMPLES.glob('*.c'))}
VENDOR = ROOT / 'vendor'
CORE_DEFINES = {'ibex': 'IBEX', 'picorv32': 'PICO', 'serv': 'SERV', 'vexriscv': 'VEX'}
CORES = tuple(CORE_DEFINES)
BRAM_BYTES = 256 * 1024


def write_bram_image(image, path):
    if not 0 < len(image) <= BRAM_BYTES:
        raise ValueError(f'BRAM image must contain 1 to {BRAM_BYTES} bytes')
    padded = image.ljust(BRAM_BYTES, b'\0')
    path.write_text(''.join(f"{int.from_bytes(padded[i:i + 8], 'little'):016x}\n"
                            for i in range(0, BRAM_BYTES, 8)))


def logged(command, log):
    with log.open('w') as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise ValueError(f'{Path(command[0]).name} exited {result.returncode}, see {log}')


def riscv_image(core, name, work):
    gcc = os.environ.get('RISCV_GCC', 'riscv64-elf-gcc')
    objcopy = os.environ.get('RISCV_OBJCOPY', str(gcc).removesuffix('gcc') + 'objcopy')
    arch = 'rv32i' if core == 'serv' else 'rv32im'
    base, offset = (0x80000000, 0) if core == 'vexriscv' else (0, 128)
    elf = work / f'{name}.elf'
    binary = work / f'{name}.bin'
    if name == 'coremark':
        sources = [COREMARK_PORT / 'kernels.c', *[
            COREMARK_UPSTREAM / f'core_{part}.c' for part in ('list_join', 'matrix', 'state', 'util')]]
        options = ['-DMDMA_RISCV_BENCH', '-I', COREMARK_PORT, '-I', COREMARK_UPSTREAM]
    else:
        sources = [SOURCES[name]]
        options = []
    logged([gcc, '-O2', f'-march={arch}', '-mabi=ilp32', '-ffreestanding', '-fno-pic',
            '-msmall-data-limit=0', '-mno-relax', '-ffunction-sections', '-fdata-sections',
            '-nostdlib', '-Wl,--gc-sections', f'-Wl,--defsym=RAM_BASE={base},--defsym=BOOT_OFFSET={offset}',
            '-T', HERE / 'memory.ld', '-o', elf, *options, HERE / 'start.S', *sources, '-lgcc'],
           work / f'{name}-gcc.log')
    subprocess.run([objcopy, '-O', 'binary', elf, binary], check=True)
    return bytes(offset) + binary.read_bytes()


def rv_sources(core):
    defines = [f'-DMDMA_COMPARE_{CORE_DEFINES[core]}']
    ports = os.environ.get('MDMA_BRAM_PORTS', '1')
    if ports not in ('1', '2'):
        raise ValueError('MDMA_BRAM_PORTS must be 1 or 2')
    defines.append(f'-DMDMA_BRAM_PORTS={ports}')
    if core == 'picorv32':
        upstream = [VENDOR / core / 'picorv32.v']
    elif core == 'serv':
        upstream = sorted((VENDOR / core / 'rtl').glob('*.v'))
    elif core == 'vexriscv':
        upstream = [Path(os.environ.get('VEXRISCV_RTL', 'build/compare/VexRiscv.v')).resolve()]
    else:
        ibex = VENDOR / 'ibex/rtl'
        ip = VENDOR / 'ibex/vendor/lowrisc_ip/ip'
        prim = ip / 'prim/rtl'
        generic = ip / 'prim_generic/rtl'
        defines += [f'-I{prim}', f'-I{ibex}',
                    f'-I{ip.parent / "dv/sv/dv_utils"}', '-DSYNTHESIS']
        upstream = [prim / f'prim_{kind}_pkg.sv'
                    for kind in ('util', 'secded', 'cipher', 'count', 'mubi')]
        upstream += [generic / 'prim_ram_1p_pkg.sv', ibex / 'ibex_pkg.sv', ibex / 'ibex_cheriot_pkg.sv']
        upstream += [generic / f'prim_{kind}.sv' for kind in ('and2', 'buf', 'clock_gating', 'flop')]
        upstream += [p for p in sorted(ibex.glob('ibex_*.sv'))
                     if p not in upstream and 'trac' not in p.stem]
    missing = [str(path) for path in upstream if not path.is_file()]
    if not upstream or missing:
        raise ValueError(f'missing {core} RTL: {", ".join(missing) or VENDOR / core}')
    soc = [HERE / name for name in ('board.v', 'mdma_soc.v', 'mdma_bram.v', 'mdma_mmio.v', 'mdma_uart.v')]
    return defines, [*upstream, *soc, HERE / 'riscv_cpu.sv', HERE / 'compare_top.v']


def rv_simulator(core, work):
    defines, sources = rv_sources(core)
    top = 'mdma_compare_riscv_tb'
    obj = work / 'obj'
    logged([os.environ.get('VERILATOR', 'verilator'), '--binary', '--timing', '-O3',
            '-CFLAGS', '-O3', '-j', '4', '-Wno-fatal', '--top-module', top, '--Mdir', obj,
            *defines, *sources, HERE / 'riscv_tb.sv'], work / 'sim-build.log')
    return obj / f'V{top}'


def run_riscv(executable, image, name, work):
    path = work / f'{name}.hex'
    write_bram_image(image, path)
    log = work / f'{name}-sim.log'
    logged([executable, f'+image={path}', *(['+timed'] if name == 'coremark' else [])], log)
    match = re.search(r'^BENCH (\d+) (\d+) ([0-9a-fA-F]+) ((?:\d+ ?){4})$',
                      log.read_text(), re.MULTILINE)
    if not match or int(match[3], 16) != EXPECTED.get(name, 0):
        raise ValueError(f'{name} failed result check, see {log}')
    return int(match[1]), int(match[2]), list(map(int, match[4].split()))


def route(core, image, work):
    path = work / 'bram.hex'
    write_bram_image(image, path)
    netlist = work / 'netlist.json'
    top = 'mdma_compare_top'
    defines, sources = rv_sources(core)
    if core == 'ibex':
        # Slang rejects a dynamic initializer on this unused lint signal.
        # A net declaration expresses the intended continuous assignment.
        top_source = VENDOR / 'ibex/rtl/ibex_top.sv'
        compatible = work / top_source.name
        compatible.write_text(top_source.read_text().replace(
            'logic unused_scramble_inputs =', 'wire unused_scramble_inputs ='))
        sources[sources.index(top_source)] = compatible
    read = ['read_slang', '--top', top, f'-G INIT_FILE="{path}"',
            *defines, *map(str, sources)]
    read_command = ' '.join(read)
    logged(['yosys', '-Q', '-T', '-p', f'{read_command}; synth_ecp5 -top {top} -json {netlist}'],
           work / 'synth.log')
    report = work / 'route.json'
    router = os.environ.get('MDMA_ECP5_ROUTER')
    route_options = ['--router', router] if router else []
    if router == 'router2':
        route_options += ['--threads', '4', '--parallel-refine']
    logged([os.environ.get('NEXTPNR_ECP5', 'nextpnr-ecp5'), '--um5g-85k', '--package', 'CABGA381',
            '--speed', '8', '--freq', '25', '--seed', '1', '--timing-allow-fail',
            '--lpf-allow-unconstrained', *route_options, '--json', netlist, '--report', report,
            '--textcfg', work / 'design.config'], work / 'route.log')
    data = json.loads(report.read_text())
    return (min(clock['achieved'] for clock in data['fmax'].values()),
            {key: item['used'] for key, item in data['utilization'].items()})


def run_core(core, names, work, timing):
    work.mkdir(parents=True, exist_ok=True)
    executable = rv_simulator(core, work)
    results = {}
    for name in names:
        image = riscv_image(core, name, work)
        timed, total, counters = run_riscv(executable, image, name, work)
        results[name] = {'image_bytes': len(image), 'total_clocks': total}
        if name == 'coremark':
            results[name].update(workload_clocks=timed, coremark_per_mhz=1_000_000 / timed,
                                 bram_instruction_reads=counters[0], bram_data_reads=counters[1],
                                 bram_data_writes=counters[2], instruction_port_wait=counters[3])
            coremark_image = image
        print(f'{core:8} {name:12} {total:>10,} total clocks  {len(image):>7,} image bytes', flush=True)
    result_path = work / 'results.json'
    result_path.write_text(json.dumps(results, indent=2) + '\n')
    if timing:
        fmax, utilization = route(core, coremark_image, work)
        results['coremark'].update(fmax_mhz=fmax, coremark_per_second=fmax * results['coremark']['coremark_per_mhz'])
        results['resources'] = utilization
        result_path.write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results['coremark']), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cores', nargs='*', metavar='CORE', help='one or more of ' + ', '.join(CORES))
    parser.add_argument('--coremark-only', action='store_true')
    parser.add_argument('--route', action='store_true', help='synthesize and route on the ECP5 -8')
    parser.add_argument('--summary', action='store_true', help='print tables from existing results')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/compare')
    args = parser.parse_args()
    names = ['coremark'] if args.coremark_only else ['coremark', *SOURCES]
    cores = args.cores or CORES
    for core in cores:
        if core not in CORES:
            parser.error(f'unknown core {core}')
    if args.summary:
        try:
            summarize(args.output, cores)
        except (OSError, ValueError) as error:
            parser.exit(1, f'{error}\n')
        return 0
    failed = False
    for core in cores:
        try:
            run_core(core, names, args.output.resolve() / core, args.route)
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            print(f'{core}: {error}', file=sys.stderr)
            failed = True
    return failed


def summarize(output, cores):
    results = {core: json.loads((output / core / 'results.json').read_text()) for core in cores}
    print('| Core | CoreMark clocks | Total clocks | CoreMark/MHz | CoreMark/s at 25 MHz | Routed MHz | CoreMark/s at routed limit | Image bytes |')
    print('| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
    for core, rows in results.items():
        row = rows['coremark']
        fmax = f"{row['fmax_mhz']:.2f}" if 'fmax_mhz' in row else '—'
        rate = f"{row['coremark_per_second']:.2f}" if 'coremark_per_second' in row else '—'
        print(f"| {core} | {row['workload_clocks']:,} | {row['total_clocks']:,} | "
              f"{row['coremark_per_mhz']:.5f} | {25 * row['coremark_per_mhz']:.2f} | "
              f"{fmax} | {rate} | {row['image_bytes']:,} |")
    print('\n| Core | Logic cells | FFs | BRAM blocks | Multipliers | BRAM instruction reads | Data reads | Data writes | Fetch port wait clocks |')
    print('| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
    for core, rows in results.items():
        resources = rows.get('resources', {})
        cells = [f'{resources[key]:,}' if key in resources else '—'
                 for key in ('TRELLIS_COMB', 'TRELLIS_FF', 'DP16KD', 'MULT18X18D')]
        counts = [f"{rows['coremark'][key]:,}" for key in
                  ('bram_instruction_reads', 'bram_data_reads', 'bram_data_writes', 'instruction_port_wait')]
        print('| ' + ' | '.join([core, *cells, *counts]) + ' |')
    print('\nTotal clocks for the checked example programs\n')
    print('| Example | ' + ' | '.join(cores) + ' |')
    print('| --- |' + ' ---: |' * len(cores))
    for name in SOURCES:
        if any(name in rows for rows in results.values()):
            clocks = [f"{rows[name]['total_clocks']:,}" if name in rows else '—' for rows in results.values()]
            print('| ' + ' | '.join([name, *clocks]) + ' |')


if __name__ == '__main__':
    sys.exit(main())
