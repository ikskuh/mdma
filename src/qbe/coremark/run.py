"""Validate and time the pinned CoreMark kernels in the simulator."""

import argparse
import os
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


def compile_inputs(work):
    cproc = shutil.which(os.environ.get('CPROC', 'cproc'))
    if not cproc:
        raise ValueError('install cproc or set CPROC to its executable')
    sources = [PORT / 'kernels.c'] + [
        UPSTREAM / f'core_{name}.c' for name in ('list_join', 'matrix', 'state', 'util')]
    includes = ['-I', PORT, '-I', UPSTREAM]
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
    return inputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--schedule', type=Path, help='override the scheduling profile')
    mode.add_argument('--no-schedule', action='store_true', help='run the original backend')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='mdma-coremark-') as directory:
        work = Path(directory)
        inputs = compile_inputs(work)
        asm = work / 'coremark.mdma'
        profile = args.schedule or PORT.parent / 'profiles' / 'simulator.conf'
        options = ['--no-schedule'] if args.no_schedule else ['--schedule', profile]
        subprocess.run([ROOT / 'build/qbe-mdma', *options, '-o', asm, *inputs], check=True)
        density = MoveDensity()
        image, labels = assemble_with_labels(asm.read_text(), density=density)
        checks = {name: labels[exported(f'coremark_{name}_crc')] for name in CRCS}
        checks['result'] = labels['__mdma_result']
        start, end = (labels[exported(f'coremark_{name}')] for name in ('iteration', 'timed_end'))
        print(f'Running {len(image):,}-byte MDMA image on the simulator.', flush=True)
        print(density, flush=True)
        image += bytes(65536)
        timed, total, values = functional(image, checks, start, end,
                                           None if args.no_schedule else profile)

    for name, expected, actual in zip(CRCS, CRCS.values(), values):
        if actual != expected:
            raise ValueError(f'{name} CRC expected 0x{expected:04x}, got 0x{actual:04x}')
        print(f'{name} CRC 0x{actual:04x}')
    if values[-1] != 0:
        raise ValueError(f'MDMA kernel driver returned {values[-1]}')
    print(f'Timed one iteration in {timed:,} simulator ticks. Halted after {total:,} simulator ticks.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f'CoreMark: {exc}')
