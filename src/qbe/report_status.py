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
PROFILES = ROOT / 'src/qbe/profiles'
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
    rtl_profiles = []
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

        rtl = work / 'rtl'
        rtl.mkdir()
        executable = coremark.build_ecp5(rtl)
        for name, inputs, function, expected in workloads:
            for target, profile in (
                ('Simulator, one clock', PROFILES / 'one-clock.conf'),
                ('ECP5 RTL', PROFILES / 'ecp5.conf'),
            ):
                print(f'Running {name} on {target}...', flush=True)
                asm = work / 'program.mdma'
                subprocess.run([ROOT / 'build/qbe-mdma', '--schedule', profile,
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
                checks = {key: labels[coremark.exported('coremark_' + key + '_crc')]
                          for key in coremark.CRCS} if function is None else {}
                checks['result'] = labels['__mdma_result']
                expected_values = [*coremark.CRCS.values(), 0] if function is None else [expected] * 4
                if function:
                    checks = dict.fromkeys((*coremark.CRCS, 'result'), checks['result'])
                image += bytes(65536)
                start_pc, end_pc = labels[entry], labels[end]
                if target == 'ECP5 RTL':
                    profile_counters = {}
                    timed, total, values = coremark.ecp5(rtl, image, checks, start_pc, end_pc, executable,
                                                         profile=profile_counters)
                    rtl_profiles.append((name, timed, profile_counters))
                else:
                    timed, total, values = coremark.functional(image, checks, start_pc, end_pc, profile)
                if values != expected_values:
                    raise ValueError(f'{name} on {target}: expected {expected_values}, got {values}')
                score = f'{1_000_000 / timed:.8f}' if function is None else '—'
                rows.append((name, target, timed, total, score))
                print('Result checks passed.', flush=True)

    print('\nSimulator ticks are treated as CPU clocks. Every simulator FU has latency and issue interval 1.')
    print('ECP5 RTL uses CPU-clock BRAM and a 1:1 math-to-CPU clock ratio.')
    print('Workload clocks cover the CoreMark iteration or one function call. Total clocks cover boot through halt.')
    print('CoreMark/MHz is 1,000,000 divided by the timed iteration clocks.\n')
    print('| Workload | Target | Workload clocks | Total clocks | CoreMark/MHz |')
    print('| --- | --- | ---: | ---: | ---: |')
    for name, target, timed, total, score in rows:
        print(f'| {name} | {target} | {timed:,} | {total:,} | {score} |')

    print('\nI-cache hits, misses, and refills are unavailable with direct BRAM fetch.')
    print(f'ECP5 BRAM port mode is {rtl_profiles[0][2]["bram_ports"]}.')
    print('| Workload | Retired instructions | Instructions/clock | BRAM instruction reads | BRAM data reads | BRAM data writes | Instruction port wait clocks |')
    print('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
    for name, timed, counters in rtl_profiles:
        values = ' | '.join(f'{counters[key]:,}' for key in
                            ('bram_instruction_reads', 'bram_data_reads', 'bram_data_writes', 'bram_instruction_port_wait'))
        print(f'| {name} | {counters["retired"]:,} | {counters["retired"] / timed:.8f} | {values} |')

    stream = rtl_profiles[0][2]
    ahead = stream['ahead_words']
    print(f'\nInstruction stream holds {stream["stream_words"]} words '
          f'with {ahead} ahead and {stream["stream_words"] - ahead} retained.')
    print('| Workload | Resident redirect hits | Redirect misses | Redirect to admit (avg / max clocks) | History evictions | Peak unread words | Full-window clocks |')
    print('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
    for name, _, counters in rtl_profiles:
        admitted = counters['redirects_admitted']
        latency = f'{counters["redirect_to_admit_total"] / admitted:.2f} / {counters["redirect_to_admit_max"]}' if admitted else '—'
        print(f'| {name} | {counters["resident_redirect_hits"]:,} | {counters["resident_redirect_misses"]:,} | '
              f'{latency} | {counters["history_evictions"]:,} | {counters["stream_highwater"]:,} | {counters["window_full"]:,} |')

    print('\nClock categories below plus retired instructions sum to workload clocks.')
    print('CONST stalls mean that supplying CONST would let the instruction finish. Concurrent FU/predicate waits are other execute waits.')
    print('Next-instruction stalls exclude redirect lookup, cancellation, and clocks admitting an instruction into an empty execute slot.')
    print('| Workload | CONST stalls | Next-instruction stalls | Redirect stalls | Other execute waits | Decode bubbles |')
    print('| --- | ---: | ---: | ---: | ---: | ---: |')
    for name, _, counters in rtl_profiles:
        values = ' | '.join(f'{counters[key]:,}' for key in
                            ('const_stall', 'instruction_stall', 'redirect_stall', 'execute_wait', 'decode_bubble'))
        print(f'| {name} | {values} |')

    print('\nCONST word-absent clocks can overlap other execution waits.')
    print('| Workload | CONST stall episodes | Next-instruction stall episodes | CONST word-absent clocks |')
    print('| --- | ---: | ---: | ---: |')
    for name, _, counters in rtl_profiles:
        print(f'| {name} | {counters["const_stall_events"]:,} | {counters["instruction_stall_events"]:,} | '
              f'{counters["const_fifo_empty"]:,} |')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f'report-status: {exc}')
