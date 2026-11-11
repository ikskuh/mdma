"""Compile, check, and time the C workloads on the MDMA simulator."""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path[:0] = [str(ROOT / 'src/assembler'), str(ROOT / 'src/simulator')]
from mdma_asm import assemble_with_labels
from simulator import Simulator


EXAMPLES = {
    'bubble_sort': 'bubble_sort',
    'quick_sort': 'quick_sort',
    'fibonacci': 'fibonacci',
    'mat_mul': 'mat_mul',
    'crc32': 'crc32',
    'rgba_blend': 'rgba_over',
    'strcpy': 'copy_string',
    'memmove': 'move_bytes',
    'bresenham': 'bresenham',
    'sha256': 'sha256',
    'goertzel': 'goertzel_power',
}
PROFILES = ROOT / 'src/qbe/profiles'


def measure(image, labels, kernel, profile):
    entries = {name: labels['__mdma_g0_' + name.encode().hex()] for name in ('main', kernel)}
    active = {}
    clocks = dict.fromkeys(entries, 0)
    calls = dict.fromkeys(entries, 0)
    sim = Simulator(image, memory_size=len(image) + 65536, profile=profile)
    while not sim.halted and sim.ticks < 1_000_000:
        if sim.instruction is None:
            for name, entry in entries.items():
                if name in active:
                    start, continuation = active[name]
                    if sim.stream.pc == continuation:
                        clocks[name] += sim.ticks - start
                        calls[name] += 1
                        del active[name]
                elif sim.stream.pc == entry:
                    # The preceding instruction was the call. Its fall-through
                    # is the return address, even for an extended call pack.
                    active[name] = sim.ticks, sim.stream.next_pc
        sim.tick()
    if not sim.halted:
        raise ValueError(f'tick limit reached at PC {sim.stream.pc:#x}')
    if active or calls['main'] != 1 or not calls[kernel]:
        raise ValueError('main or kernel timing boundaries were not reached')
    address = labels['__mdma_result']
    result = int.from_bytes(sim.memory[address:address + 8], 'little')
    if result != 0:
        raise ValueError(f'self-check returned {result}')
    return calls[kernel], clocks[kernel], clocks['main'], sim.ticks


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog='Examples: ' + ', '.join(EXAMPLES))
    parser.add_argument('names', nargs='*', help='example names, or omit to run all')
    args = parser.parse_args()
    for name in args.names:
        if name not in EXAMPLES:
            parser.error(f'unknown example {name!r}')

    print('One tick is one simulated clock. Both profiles run the same image.')
    print('Kernel clocks sum outer calls, including nested work. Main includes self-checks.')
    print('Total covers boot through halt. All reported runs passed their self-checks.\n')
    print('| Example | Profile | Image bytes | Kernel calls | Kernel clocks | Main clocks | Total clocks |')
    print('| --- | --- | ---: | ---: | ---: | ---: | ---: |', flush=True)

    with tempfile.TemporaryDirectory(prefix='mdma-examples-') as directory:
        work = Path(directory)
        for name in args.names or EXAMPLES:
            il = work / f'{name}.ssa'
            try:
                subprocess.run([os.environ.get('CPROC', 'cproc'), '-emit-qbe', '-nostdinc',
                                '-o', il, HERE / f'{name}.c'], check=True)
                assembly = subprocess.check_output(
                    [ROOT / 'build/qbe-mdma', '--schedule', PROFILES / 'simulator.conf', il], text=True)
                image, labels = assemble_with_labels(assembly)
            except (OSError, ValueError, subprocess.CalledProcessError) as exc:
                sys.exit(f'{name}: {exc}')
            for profile in ('one-clock', 'simulator'):
                try:
                    calls, kernel, main_clocks, total = measure(
                        image, labels, EXAMPLES[name], PROFILES / f'{profile}.conf')
                except (OSError, ValueError, KeyError) as exc:
                    sys.exit(f'{name} ({profile}): {exc}')
                print(f'| {name} | {profile} | {len(image):,} | {calls:,} | {kernel:,} | '
                      f'{main_clocks:,} | {total:,} |', flush=True)


if __name__ == '__main__':
    main()
