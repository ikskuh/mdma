"""Host runner for the FIFO-based MDMA simulator."""

import argparse
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


class Simulator(core.SimulatorCore):
    def __init__(self, image: bytes, memory_size=None, latencies=None):
        if memory_size is not None and memory_size < len(image):
            raise SimulationError('memory size is smaller than image')
        memory = bytearray(image)
        memory.extend(b'\0' * ((memory_size or len(image)) - len(image)))
        latencies = {} if latencies is None else latencies
        allowed = set(core.UNIT_TYPES) | {str(instance) for instance in core.INSTANCES}
        for name, latency in latencies.items():
            if name not in allowed:
                raise SimulationError(f'unknown unit latency override {name!r}')
            if type(latency) is not int or latency < 1:
                raise SimulationError('unit latency must be a positive integer')
        unit_latencies = {}
        for instance in core.INSTANCES:
            family = instance.unit.name
            default = core.UNIT_TYPES[family].default_latency
            unit_latencies[instance] = latencies.get(str(instance), latencies.get(family, default))
        super().__init__(memory, unit_latencies)

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
    parser.add_argument('--trace', action='store_true')
    parser.add_argument('--dump-memory', type=Path, help='write final memory after successful halt')
    args = parser.parse_args()
    if args.max_ticks <= 0 or (args.memory_size is not None and args.memory_size <= 0):
        parser.error('tick limit and memory size must be positive')
    try:
        simulator = Simulator(args.input.read_bytes(), args.memory_size, latencies=dict(args.latency))
        simulator.run(args.max_ticks, args.trace)
        if args.dump_memory:
            args.dump_memory.write_bytes(simulator.memory)
        print(f'halted after {simulator.ticks} ticks (jump to -1)')
    except (OSError, SimulationError) as exc:
        print(f'mdma simulator: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
