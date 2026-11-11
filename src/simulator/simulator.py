"""Host runner for the FIFO-based MDMA simulator."""

import argparse
import re
import sys
from pathlib import Path

if __package__:
    from . import simulator_core as core
else:
    import simulator_core as core

DEPTH = core.DEPTH
MASK = core.MASK
Instruction = core.Instruction
Queue = core.Queue
SimulationError = core.SimulationError
State = core.State


MEM_TIMINGS = ('MEM_READ', 'MEM_WRITE')
PROFILE_UNITS = {str(unit) for unit in core.INSTANCES} - {'MEM'} | set(MEM_TIMINGS)


def read_profile(path):
    timings = {}
    seen_stack = False
    with Path(path).open(encoding='utf-8') as profile:
        for line, raw in enumerate(profile, 1):
            row = raw.partition('#')[0].split()
            if not row:
                continue
            name, *fields = row
            location = f'{path}:{line}'
            if name == 'stack_push_ordered':
                if seen_stack or fields != ['yes']:
                    raise SimulationError(f'{location}: expected stack_push_ordered yes (stack ordering is required)')
                seen_stack = True
                continue
            if name not in PROFILE_UNITS:
                raise SimulationError(f'{location}: unknown unit {name}')
            if name in timings:
                raise SimulationError(f'{location}: duplicate unit {name}')
            if len(fields) != 2 or any(not re.fullmatch(r'\+?[0-9]+', value) or
                                       not 1 <= int(value) <= 10000 for value in fields):
                raise SimulationError(f'{location}: expected UNIT LATENCY ISSUE_INTERVAL for {name}')
            timings[name] = tuple(map(int, fields))
    missing = sorted(PROFILE_UNITS - timings.keys())
    if missing:
        raise SimulationError(f'{path}: missing unit {missing[0]}')
    return timings


class Simulator(core.SimulatorCore):
    def __init__(self, image: bytes, memory_size=None, latencies=None, *, profile=None):
        if memory_size is not None and memory_size < len(image):
            raise SimulationError('memory size is smaller than image')
        memory = bytearray(image)
        memory.extend(b'\0' * ((memory_size or len(image)) - len(image)))
        latencies = {} if latencies is None else latencies
        allowed = core.UNIT_TYPES.keys() | PROFILE_UNITS
        for name, latency in latencies.items():
            if name not in allowed:
                raise SimulationError(f'unknown unit latency override {name!r}')
            if type(latency) is not int or latency < 1:
                raise SimulationError('unit latency must be a positive integer')
        configured = {} if profile is None else read_profile(profile)
        timings = {}
        for instance in core.INSTANCES:
            family = instance.unit.name
            default = core.UNIT_TYPES[family].default_latency
            names = MEM_TIMINGS if family == 'MEM' else (str(instance),)
            timing = []
            for name in names:
                latency, interval = configured.get(name, (default, default))
                latency = latencies.get(name, latencies.get(family, latency))
                timing.extend((latency, interval if configured else latency))
            timings[instance] = timing
        super().__init__(memory, timings)

    def tick(self):
        return False if self.halted else super().tick()

    def run(self, max_ticks=100000, trace=False):
        for _ in range(max_ticks):
            if self.halted:
                return
            if trace:
                print(f'tick={self.ticks} pc={self.stream.pc:#x}', file=sys.stderr)
            self.tick()
        if not self.halted:
            raise SimulationError(f'tick limit reached ({max_ticks}) at PC {self.stream.pc:#x}')


def parse_latency(value):
    name, separator, ticks = value.partition('=')
    try:
        latency = int(ticks)
    except ValueError:
        latency = 0
    if not separator or not name or latency < 1:
        raise argparse.ArgumentTypeError('expected UNIT=TICKS with a positive integer tick count')
    return name, latency


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--max-ticks', type=int, default=100000)
    parser.add_argument('--memory-size', type=int, help='zero-filled memory size in bytes (default: image size)')
    parser.add_argument('--latency', type=parse_latency, action='append', default=[], metavar='UNIT=TICKS',
                        help='override unit/family latency; repeatable')
    parser.add_argument('--profile', type=Path, help='load a QBE latency and issue-interval profile')
    parser.add_argument('--trace', action='store_true')
    parser.add_argument('--dump-memory', type=Path, help='write final memory after successful halt')
    args = parser.parse_args()
    if args.max_ticks <= 0 or (args.memory_size is not None and args.memory_size <= 0):
        parser.error('tick limit and memory size must be positive')
    try:
        simulator = Simulator(args.input.read_bytes(), args.memory_size,
                              latencies=dict(args.latency), profile=args.profile)
        simulator.run(args.max_ticks, args.trace)
        if args.dump_memory:
            args.dump_memory.write_bytes(simulator.memory)
        print(f'halted after {simulator.ticks} ticks (jump to -1)')
    except (OSError, ValueError) as exc:
        print(f'mdma simulator: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
