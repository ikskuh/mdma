"""Compile and check the self-testing C workloads on the MDMA simulator."""

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


EXAMPLES = (
    'bubble_sort', 'quick_sort', 'fibonacci', 'mat_mul', 'crc32', 'rgba_blend',
    'strcpy', 'memmove', 'bresenham', 'sha256', 'goertzel',
)
PROFILE = ROOT / 'src/qbe/profiles/simulator.conf'


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog='Examples: ' + ', '.join(EXAMPLES))
    parser.add_argument('names', nargs='*', help='example names, or omit to run all')
    args = parser.parse_args()
    for name in args.names:
        if name not in EXAMPLES:
            parser.error(f'unknown example {name!r}')

    with tempfile.TemporaryDirectory(prefix='mdma-examples-') as directory:
        work = Path(directory)
        for name in args.names or EXAMPLES:
            il = work / f'{name}.ssa'
            try:
                subprocess.run([os.environ.get('CPROC', 'cproc'), '-emit-qbe', '-nostdinc',
                                '-o', il, HERE / f'{name}.c'], check=True)
                assembly = subprocess.check_output(
                    [ROOT / 'build/qbe-mdma', '--schedule', PROFILE, il], text=True)
                image, labels = assemble_with_labels(assembly)
                sim = Simulator(image, memory_size=len(image) + 65536, profile=PROFILE)
                sim.run(max_ticks=1_000_000)
                address = labels['__mdma_result']
                result = int.from_bytes(sim.memory[address:address + 8], 'little')
                if result != 0:
                    raise ValueError(f'self-check returned {result}')
            except (OSError, ValueError, subprocess.CalledProcessError) as exc:
                sys.exit(f'{name}: {exc}')
            print(f'PASS {name:<12} {len(image):>6,} bytes  {sim.ticks:>7,} ticks', flush=True)


if __name__ == '__main__':
    main()
