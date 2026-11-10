"""FIFO-based MDMA simulator. Memory and instruction fetching live outside State."""

import sys
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'pylibs'))
from mdma import SINK_BY_INDEX, SOURCE_BY_INDEX

MASK = (1 << 64) - 1
DEPTH = 8


class SimulationError(ValueError):
    def __init__(self, message, *, code=None):
        super().__init__(message)
        self.code = code


def signed(value, bits=64):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


class Queue:
    def __init__(self):
        self.values = deque()

    def writable(self):
        return len(self.values) < DEPTH

    def write(self, value):
        self.values.append(value & MASK)


class Constant:
    def __init__(self, value=0):
        self.value = value

    def ready(self, staged):
        return True

    def read(self, staged):
        return self.value


class Discard:
    def writable(self):
        return True

    def write(self, value):
        pass


class Reserved:
    def writable(self):
        raise SimulationError('write to reserved sink', code='reserved_sink')

    def ready(self, staged):
        raise SimulationError('read from reserved source', code='reserved_source')


class Output:
    """A unit owns retirement of its output generations, including sibling outputs."""
    def __init__(self, unit, name):
        self.unit = unit
        self.name = name

    def ready(self, staged):
        return self in staged or bool(self.unit.results)

    def read(self, staged):
        if self not in staged:
            values = self.unit.take_result()
            for name, endpoint in self.unit.outputs.items():
                staged[endpoint] = values[name]
        return staged[self]


@dataclass
class State:
    sinks: list
    sources: list


@dataclass
class Instruction:
    moves: list[tuple[int, int]]
    synchronized: bool = False
    predicate: bool = False
    staged: dict = field(default_factory=dict)
    completed: set = field(default_factory=set)
    predicate_checked: bool = False
    finished: bool = False

    @classmethod
    def decode(cls, word):
        mode = (word >> 60) & 3
        moves = []
        sink = -1
        for slot in range(4 if mode in (2, 3) else 5):
            pair = (word >> (12 * slot)) & 4095
            sink = min(63, sink + (pair >> 6) + 1)
            moves.append((pair & 63, sink))
        return cls(moves, bool(word & (1 << 62)), bool(word & (1 << 63)))

    def execute(self, state):
        progress = False
        if self.predicate and not self.predicate_checked:
            condition = state.sinks[62]
            if not condition.values:
                return False
            self.predicate_checked = True
            progress = True
            if not condition.values.popleft():
                self.finished = True
                return True
        pending = [(i, state.sources[src], state.sinks[dst])
                   for i, (src, dst) in enumerate(self.moves) if i not in self.completed]
        if self.synchronized and not all(src.ready(self.staged) and dst.writable()
                                         for _, src, dst in pending):
            return progress
        writes = []
        try:
            for i, src, dst in pending:
                if src.ready(self.staged) and dst.writable():
                    writes.append((dst, src.read(self.staged)))
                    self.completed.add(i)
                    progress = True
        finally:
            # All reads on this edge see the old heads, including stack
            # exchanges. Preserve earlier transfers if a later move faults.
            for dst, value in writes:
                dst.write(value)
        self.finished = len(self.completed) == len(self.moves)
        return progress


def check_memory(memory, address):
    if address + 8 > len(memory):
        raise SimulationError(f'memory access outside image at {address:#x}', code='memory_bounds')


def read_word(memory, address):
    check_memory(memory, address)
    return int.from_bytes(memory[address:address + 8], 'little')


class Unit:
    default_latency = 1
    output_depth = DEPTH

    def __init__(self, instance, state, memory, latency, interval):
        self.latency = latency
        self.interval = interval
        self.pending = deque()
        self.clock = self.next_issue = 0
        self.inputs = {}
        self.outputs = {}
        self.results = deque()
        for index, info in SINK_BY_INDEX.items():
            if info.unit == instance:
                self.inputs[info.name] = state.sinks[index] = Queue()
        for index, info in SOURCE_BY_INDEX.items():
            if info.unit == instance:
                self.outputs[info.name] = state.sources[index] = Output(self, info.name)

    def take_result(self):
        return self.results.popleft()

    @property
    def busy(self):
        return bool(self.pending)

    @property
    def has_complete_request(self):
        return all(queue.values for queue in self.inputs.values())

    def take_inputs(self, draining=False):
        if not self.has_complete_request:
            return None
        if len(self.results) + len(self.pending) >= self.output_depth and not draining:
            return None
        return [queue.values.popleft() for queue in self.inputs.values()]

    def timing(self, *inputs):
        return self.latency, self.interval

    def execute(self, draining=False):
        self.clock += 1
        if self.clock >= self.next_issue:
            inputs = self.take_inputs(draining=draining)
            if inputs is not None:
                latency, interval = self.timing(*inputs)
                self.next_issue = self.clock + interval
                self.pending.append((self.clock + latency - 1, inputs))
        active = self.busy
        while self.pending and self.pending[0][0] <= self.clock:
            _, inputs = self.pending.popleft()
            results = self.compute(*inputs)
            if results and len(self.results) < self.output_depth:
                self.results.append({name: int(value) & MASK for name, value in results.items()})
        return active or (self.clock < self.next_issue and self.has_complete_request)


class ArithmeticUnit(Unit):
    def compute(self, a, b):
        return dict(ADD=a + b, SUB=a - b)


class LogicUnit(Unit):
    def compute(self, a, b):
        return dict(AND=a & b, OR=a | b, XOR=a ^ b)


class ShiftUnit(Unit):
    def compute(self, a, b):
        n = b & 63
        return dict(LSL=a << n, LSR=a >> n, ASR=signed(a) >> n,
                    ROL=(a << n) | (a >> ((64 - n) & 63)),
                    ROR=(a >> n) | (a << ((64 - n) & 63)))


class CompareUnit(Unit):
    def compute(self, a, b):
        return dict(EQ=a == b, NE=a != b, LT=a < b, LTS=signed(a) < signed(b),
                    LTE=a <= b, LTES=signed(a) <= signed(b))


class MultiplyUnit(Unit):
    default_latency = 2

    def compute(self, a, b):
        product = a * b
        return dict(LO=product, HI=product >> 64)


class SignedMultiplyUnit(MultiplyUnit):
    def compute(self, a, b):
        return super().compute(signed(a), signed(b))


class DivideUnit(Unit):
    default_latency = 7

    def compute(self, a, b):
        if not b:
            raise SimulationError('division by zero', code='division_by_zero')
        quotient = abs(a) // abs(b)
        if (a < 0) != (b < 0):
            quotient = -quotient
        return dict(REM=a - quotient * b, QUO=quotient)


class SignedDivideUnit(DivideUnit):
    def compute(self, a, b):
        return super().compute(signed(a), signed(b))


class MaskUnit(Unit):
    def compute(self, a):
        return dict(MASK=(1 << a) - 1 if a < 64 else MASK, BIT=1 << a if a < 64 else 0)


class UnaryUnit(Unit):
    def compute(self, a):
        return dict(NEG=-a, NOT=~a, BSW=int.from_bytes(a.to_bytes(8, 'little'), 'big'))


class BitCountUnit(Unit):
    def compute(self, a):
        return dict(POP=a.bit_count(), CLZ=64 - a.bit_length(), CTZ=(a & -a).bit_length() - 1 if a else 64)


class SelectUnit(Unit):
    def compute(self, condition, true, false):
        return dict(OUT=true if condition else false)


class StashUnit(Unit):
    def compute(self, value):
        return dict(OUT=value)


class StackInput(Queue):
    def __init__(self, unit):
        super().__init__()
        self.unit = unit

    def writable(self):
        return len(self.values) + len(self.unit.pending) + len(self.unit.results) < self.unit.output_depth


class StackOutput(Output):
    def ready(self, staged):
        return self in staged or (
            not self.unit.busy and not self.unit.has_complete_request and bool(self.unit.results))


class StackUnit(Unit):
    output_depth = 2 * DEPTH

    def __init__(self, instance, state, memory, latency, interval):
        super().__init__(instance, state, memory, latency, interval)
        for index, info in SINK_BY_INDEX.items():
            if info.unit == instance:
                self.inputs['PUSH'] = state.sinks[index] = StackInput(self)
        for index, info in SOURCE_BY_INDEX.items():
            if info.unit == instance:
                self.outputs['TOP'] = state.sources[index] = StackOutput(self, 'TOP')

    def compute(self, value):
        return dict(TOP=value)

    def take_result(self):
        return self.results.pop()


class MemoryUnit(Unit):
    default_latency = 4

    def __init__(self, instance, state, memory, latency, interval, write_latency, write_interval):
        super().__init__(instance, state, memory, latency, interval)
        self.write_timing = write_latency, write_interval
        self.memory = memory
        self.read_queue = self.inputs['READ'].values
        self.store_queues = tuple(self.inputs[name].values for name in ('WRITE', 'CHUNK', 'MASK'))
        self.requests = deque()
        self.queued_reads = 0
        self.queued_stores = 0

    def execute(self, draining=False):
        # Record when requests become ready even while the memory unit is busy.
        # Leave the tokens in their input FIFOs until execution can start.
        reads = len(self.read_queue) - self.queued_reads
        stores = min(map(len, self.store_queues)) - self.queued_stores
        self.queued_reads += reads
        self.queued_stores += stores
        for index in range(max(reads, stores)):
            self.requests.append((index < reads, index < stores))
        return super().execute(draining=draining)

    @property
    def has_complete_request(self):
        return bool(self.read_queue) or all(self.store_queues)

    def take_inputs(self, draining=False):
        if not self.requests:
            return None
        read, write = self.requests[0]
        if read and not draining:
            reserved = sum(inputs[0] is not None for _, inputs in self.pending)
            if len(self.results) + reserved >= DEPTH:
                return None
        self.requests.popleft()
        self.queued_reads -= read
        self.queued_stores -= write
        address = self.read_queue.popleft() if read else None
        store = tuple(queue.popleft() for queue in self.store_queues) if write else None
        return address, store

    def timing(self, address, store):
        if store is None:
            return self.latency, self.interval
        if address is None:
            return self.write_timing
        return max(self.latency, self.write_timing[0]), max(self.interval, self.write_timing[1])

    def compute(self, address, store):
        results = {}
        if address is not None:
            results['CHUNK'] = read_word(self.memory, address & ~7)
        if store is not None:
            write_address, chunk, mask = store
            base = write_address & ~7
            check_memory(self.memory, base)
            for lane in range(8):
                if not mask & (1 << lane):
                    self.memory[base + lane] = (chunk >> (lane * 8)) & 255
        return results

def lane_layout(address, type_code, operation):
    if type_code > 7:
        raise SimulationError(f'invalid type {type_code}', code='invalid_type')
    width = 1 << (type_code // 2)
    if address % width:
        raise SimulationError(f'misaligned {operation} address {address:#x}', code='misaligned_typed_address')
    return width, (address & 7) * 8


class PackUnit(Unit):
    def compute(self, address, type_code, value):
        width, shift = lane_layout(address, type_code, 'PACK')
        value_mask = (1 << (width * 8)) - 1
        return dict(ADDR=address, CHUNK=(value & value_mask) << shift,
                    MASK=255 ^ (((1 << width) - 1) << (address & 7)))


class UnpackUnit(Unit):
    def compute(self, address, type_code, chunk):
        width, shift = lane_layout(address, type_code, 'UNPACK')
        bits = width * 8
        value = (chunk >> shift) & ((1 << bits) - 1)
        return dict(VALUE=signed(value, bits) if type_code & 1 else value)


class SwizzleUnit(Unit):
    def compute(self, value, pattern):
        return dict(VALUE=sum(((value >> (((pattern >> (3 * lane)) & 7) * 8)) & 255) << (8 * lane)
                              for lane in range(8)))


# Architecture names select concrete implementations once, during initialization.
UNIT_TYPES = {
    'ARITH': ArithmeticUnit, 'LOGIC': LogicUnit, 'SHIFT': ShiftUnit,
    'CMP': CompareUnit, 'MUL': MultiplyUnit, 'MULS': SignedMultiplyUnit,
    'DIV': DivideUnit, 'DIVS': SignedDivideUnit, 'MASK': MaskUnit,
    'UOP': UnaryUnit, 'BITCNT': BitCountUnit,
    'SEL': SelectUnit, 'STASH': StashUnit, 'STACK': StackUnit,
    'MEM': MemoryUnit, 'PACK': PackUnit, 'UNPACK': UnpackUnit,
    'SWIZZLE8': SwizzleUnit,
}


class BinaryStream:
    """External instruction fetcher and provider of CPU endpoints."""
    def __init__(self, memory, state):
        self.memory = memory
        self.pc = 0
        self.next_pc = 0
        self.jump = state.sinks[0] = Queue()
        state.sinks[62] = Queue()
        state.sinks[63] = Discard()
        state.sources[0] = Constant(0)
        self.constant = state.sources[1] = Constant(1)
        self.pc_next = state.sources[2] = Constant()

    def fetch(self):
        if self.pc % 8:
            raise SimulationError(f'unaligned instruction address {self.pc:#x}', code='unaligned_pc')
        word = read_word(self.memory, self.pc)
        mode = (word >> 60) & 3
        self.next_pc = self.pc + (16 if mode == 1 else 8)
        value = 1
        if mode == 1:
            value = read_word(self.memory, self.pc + 8)
        elif mode == 2:
            value = (word >> 48) & 4095
        elif mode == 3:
            value = signed((word >> 48) & 4095, 12)
        self.constant.value = value & MASK
        self.pc_next.value = self.next_pc
        return Instruction.decode(word)

    def advance(self):
        self.pc = self.jump.values.popleft() if self.jump.values else self.next_pc


INSTANCES = tuple(dict.fromkeys(info.unit for info in SINK_BY_INDEX.values() if info.unit.unit.name != 'CPU'))


class SimulatorCore:
    def __init__(self, memory, timings):
        self.memory = memory
        self.state = State([Reserved() for _ in range(64)], [Reserved() for _ in range(64)])
        self.stream = BinaryStream(self.memory, self.state)
        self.units = [UNIT_TYPES[instance.unit.name](instance, self.state, self.memory, *timings[instance])
                      for instance in INSTANCES]
        self.instruction = None
        self.ticks = 0

    @property
    def halted(self):
        return (self.stream.pc == MASK and
                not any(unit.busy or unit.has_complete_request for unit in self.units))

    def tick(self):
        progress = False
        if self.stream.pc != MASK:
            if self.instruction is None:
                self.instruction = self.stream.fetch()
            progress = self.instruction.execute(self.state)
        for unit in self.units:
            progress = unit.execute(draining=self.stream.pc == MASK) or progress
        self.ticks += 1
        if self.instruction is not None and self.instruction.finished:
            self.stream.advance()
            self.instruction = None
            progress = True
        if not progress:
            raise SimulationError(f'stalled at PC {self.stream.pc:#x}', code='stall')
        return True
