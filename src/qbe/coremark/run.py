"""Validate and time the pinned CoreMark kernels in the simulator or ECP5 RTL."""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PORT = Path(__file__).resolve().parent
ROOT = PORT.parents[2]
UPSTREAM = ROOT / 'vendor/coremark'
sys.path[:0] = [str(ROOT / 'src/assembler'), str(ROOT / 'src/simulator')]
from mdma_asm import MoveDensity, assemble_with_labels
from rtl_runner import RTL, prepare, rtl_defines, write_image
from simulator import Simulator


CRCS = {'list': 0xe714, 'matrix': 0x1fd7, 'state': 0x8e3a}


def exported(name):
    return '__mdma_g0_' + name.encode().hex()


def functional(image, labels, start_pc, end_pc, profile):
    sim = Simulator(image, profile=profile)
    start = end = None
    while not sim.halted and sim.ticks < 50_000_000:
        if sim.instruction is None:
            if start is None and sim.stream.pc == start_pc:
                start = sim.ticks
            if end is None and sim.stream.pc == end_pc:
                end = sim.ticks
        sim.tick()
    if not sim.halted:
        raise ValueError(f'tick limit reached at PC {sim.stream.pc:#x}')
    if start is None or end is None or end <= start:
        raise ValueError('CoreMark timing boundaries were not reached')
    values = [int.from_bytes(sim.memory[address:address + 8], 'little')
              for address in labels.values()]
    return end - start, sim.ticks, values


def ecp5(work, image, labels, start_pc, end_pc):
    verilator = shutil.which(os.environ.get('VERILATOR', 'verilator'))
    if not verilator:
        raise ValueError('install Verilator or set VERILATOR to its executable')
    prepare(work)
    obj = work / 'obj'
    bench = ROOT / 'tests/rtl/mdma_coremark_tb.v'
    command = [verilator, '--binary', '--timing', '-O3', '-CFLAGS', '-O3', '-j', '4',
               '-Wno-fatal', '--top-module', 'mdma_coremark_tb', '--Mdir', obj, f'-I{work}',
               *rtl_defines(), *sorted(RTL.glob('*.v')), bench]
    build = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if build.returncode:
        raise ValueError(f'Verilator build failed:\n{build.stdout}')
    path = work / 'image.hex'
    write_image(image, path)
    result = subprocess.run([obj / 'Vmdma_coremark_tb', f'+image={path}', f'+words={len(image) // 8}',
                             f'+start_pc={start_pc}', f'+end_pc={end_pc}',
                             *(f'+{name}_word={address // 8}' for name, address in labels.items())],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    match = re.search(r'^COREMARK (\d+) (\d+) ((?:[0-9a-fA-F]+ ?){4})$', result.stdout, re.MULTILINE)
    if result.returncode or not match:
        raise ValueError(f'ECP5 simulation failed:\n{result.stdout}')
    for line in result.stdout.splitlines():
        if line.startswith('PROFILE '):
            print(line, flush=True)
    return int(match[1]), int(match[2]), [int(value, 16) for value in match[3].split()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ecp5', action='store_true', help='simulate the full board RTL with SRAM')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--schedule', type=Path, help='override the scheduling profile')
    mode.add_argument('--no-schedule', action='store_true', help='run the original backend')
    args = parser.parse_args()
    cproc = shutil.which(os.environ.get('CPROC', 'cproc'))
    if not cproc:
        raise ValueError('install cproc or set CPROC to its executable')
    sources = [PORT / 'kernels.c'] + [
        UPSTREAM / f'core_{name}.c' for name in ('list_join', 'matrix', 'state', 'util')]
    includes = ['-I', PORT, '-I', UPSTREAM]
    with tempfile.TemporaryDirectory(prefix='mdma-coremark-') as directory:
        work = Path(directory)
        native = work / 'native'
        subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-O0', *includes,
                        *sources, '-o', native], check=True)
        subprocess.run([native], check=True)
        print('Native CoreMark CRC check passed.', flush=True)
        inputs = []
        for source in sources:
            il = work / f'{source.stem}.ssa'
            subprocess.run([cproc, '-emit-qbe', '-nostdinc', *includes, '-o', il, source], check=True)
            inputs.append(il)
        asm = work / 'coremark.mdma'
        profile = args.schedule or PORT.parent / 'profiles' / ('ecp5.conf' if args.ecp5 else 'simulator.conf')
        options = ['--no-schedule'] if args.no_schedule else ['--schedule', profile]
        subprocess.run([ROOT / 'build/qbe-mdma', *options, '-o', asm, *inputs], check=True)
        density = MoveDensity()
        image, labels = assemble_with_labels(asm.read_text(), density=density)
        checks = {name: labels[exported(f'coremark_{name}_crc')] for name in CRCS}
        checks['result'] = labels['__mdma_result']
        start, end = (labels[exported(f'coremark_{name}')] for name in ('iteration', 'timed_end'))
        print(f'Running {len(image):,}-byte MDMA image on {"ECP5 RTL" if args.ecp5 else "the simulator"}.',
              flush=True)
        print(density, flush=True)
        image += bytes(65536)
        if args.ecp5:
            timed, total, values = ecp5(work, image, checks, start, end)
        else:
            timed, total, values = functional(image, checks, start, end,
                                               None if args.no_schedule else profile)

    for name, expected, actual in zip(CRCS, CRCS.values(), values):
        if actual != expected:
            raise ValueError(f'{name} CRC expected 0x{expected:04x}, got 0x{actual:04x}')
        print(f'{name} CRC 0x{actual:04x}')
    if values[-1] != 0:
        raise ValueError(f'MDMA kernel driver returned {values[-1]}')
    unit = 'CPU clocks' if args.ecp5 else 'simulator ticks'
    print(f'Timed one iteration in {timed:,} {unit}. Halted after {total:,} {unit}.')
    if args.ecp5:
        print(f'ECP5 RTL CoreMark/MHz estimate {1_000_000 / timed:.8f} (SRAM:CPU and math:CPU at 1:1).')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f'CoreMark: {exc}')
