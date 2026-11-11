"""Build and validate the workloads used in the MDMA performance report."""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from coremark import run as coremark
from mdma_asm import MoveDensity, assemble_with_labels, parse_asm


ROOT = coremark.ROOT
PROFILE = ROOT / 'src/qbe/profiles/one-clock.conf'
RETURN_MARKER = '__mdma_report_return'


def mark_return(assembly, entry):
    """Label the caller's continuation, including calls with extended immediates."""
    instructions = list(parse_asm(assembly))
    calls = [index for index, line in enumerate(instructions)
             if (line.relative or line.immediate) == entry and
             any(move.src == 'PC_NEXT' and move.dst == 'STACK_B.PUSH' for move in line.ops)]
    if len(calls) != 1:
        raise ValueError(f'expected one direct call to {entry}, found {len(calls)}')
    lines = assembly.splitlines()
    following = calls[0] + 1
    position = instructions[following].number - 1 if following < len(instructions) else len(lines)
    lines.insert(position, RETURN_MARKER + ':')
    return '\n'.join(lines) + '\n'


def main():
    cproc = shutil.which(os.environ.get('CPROC', 'cproc'))
    if not cproc:
        raise ValueError('install cproc or set CPROC to its executable')
    rows = []
    with tempfile.TemporaryDirectory(prefix='mdma-report-') as directory:
        work = Path(directory)
        inputs = coremark.compile_inputs(work)
        workloads = [('CoreMark', inputs, None, None)]
        for name, invocation, expected in (
            ('sum_to', 'sum_to(10)', 55),
            ('mix_loop', 'mix_loop(32, 0x12345678, 0x9e3779b1)', 0x41090bb9),
        ):
            il = work / (name + '.ssa')
            source = ROOT / 'examples/qbe' / (name + '.c')
            subprocess.run([cproc, '-emit-qbe', '-nostdinc', '-o', il, source], check=True)
            workloads.append((invocation, [il], name, expected))

        for name, inputs, function, expected in workloads:
            print(f'Running {name} on the one-clock simulator...', flush=True)
            asm = work / 'program.mdma'
            subprocess.run([ROOT / 'build/qbe-mdma', '--schedule', PROFILE,
                            '-o', asm, *inputs], check=True)
            assembly = asm.read_text()
            if function:
                entry = coremark.exported(function)
                assembly = mark_return(assembly, entry)
                end = RETURN_MARKER
            else:
                entry, end = (coremark.exported('coremark_' + suffix)
                              for suffix in ('iteration', 'timed_end'))
            density = MoveDensity()
            image, labels = assemble_with_labels(assembly, density=density)
            print(f'{len(image):,} bytes. {density}', flush=True)
            if function:
                checks = {}
                expected_values = [expected]
            else:
                checks = {key: labels[coremark.exported('coremark_' + key + '_crc')]
                          for key in coremark.CRCS}
                expected_values = [*coremark.CRCS.values(), 0]
            checks['result'] = labels['__mdma_result']
            image += bytes(65536)
            timed, total, values = coremark.functional(image, checks, labels[entry], labels[end], PROFILE)
            if values != expected_values:
                raise ValueError(f'{name}: expected {expected_values}, got {values}')
            score = f'{1_000_000 / timed:.8f}' if function is None else '—'
            rows.append((name, timed, total, score))
            print('Result checks passed.', flush=True)

    print('\nSimulator ticks are treated as CPU clocks. Every simulator FU has latency and issue interval 1.')
    print('Workload clocks cover the CoreMark iteration or one function call. Total clocks cover boot through halt.')
    print('CoreMark/MHz is 1,000,000 divided by the timed iteration clocks.\n')
    print('| Workload | Workload clocks | Total clocks | CoreMark/MHz |')
    print('| --- | ---: | ---: | ---: |')
    for name, timed, total, score in rows:
        print(f'| {name} | {timed:,} | {total:,} | {score} |')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f'report-status: {exc}')
