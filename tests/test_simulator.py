"""Behavioral checks for the FIFO core and the external binary runner."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src/assembler'))
sys.path.insert(0, str(ROOT / 'src/simulator'))
from mdma_asm import assemble
from simulator import (MASK, DEPTH, State, Queue, Instruction, Simulator,
                       SimulationError)
import simulator as units
from mdma import SOURCE_BY_NAME

HALT = '\nCONST -> PC [imm=-1]\n'


def machine(source):
    sim = Simulator(assemble(source + HALT))
    sim.run()
    return sim


def evaluate(unit_class, inputs):
    unit = next(unit for unit in Simulator(b'').units if type(unit) is unit_class)
    return unit.compute(*inputs)


def result(sim, name):
    return sim.state.sources[SOURCE_BY_NAME[name].index].read({})


class SimulatorTest(unittest.TestCase):
    def test_flat_core_and_partial_execution(self):
        state = State([Queue() for _ in range(64)], [Queue() for _ in range(64)])
        self.assertEqual(set(vars(state)), {'sinks', 'sources'})
        instruction = Instruction([(4, 8), (4, 9), (5, 10)])
        state.sources[4].write(42)
        self.assertTrue(instruction.execute(state))
        self.assertFalse(instruction.finished)
        self.assertEqual(list(state.sinks[8].values), [42])
        self.assertEqual(list(state.sinks[9].values), [42])
        state.sources[5].write(7)
        instruction.execute(state)
        self.assertTrue(instruction.finished)
        self.assertEqual(list(state.sinks[8].values), [42])
        self.assertEqual(list(state.sinks[10].values), [7])

    def test_synchronized_backpressure(self):
        state = State([Queue() for _ in range(64)], [Queue() for _ in range(64)])
        for _ in range(DEPTH):
            state.sinks[9].write(1)
        state.sources[4].write(42)
        instruction = Instruction([(4, 8), (4, 9)], synchronized=True)
        self.assertFalse(instruction.execute(state))
        self.assertFalse(state.sinks[8].values)
        self.assertEqual(list(state.sources[4].values), [42])
        state.sinks[9].values.popleft()
        self.assertTrue(instruction.execute(state))
        self.assertTrue(instruction.finished)
        self.assertFalse(state.sources[4].values)

    def test_counter_and_halt(self):
        sim = machine((ROOT / 'examples/counter.mdma').read_text())
        self.assertTrue(sim.halted)
        self.assertEqual(result(sim, 'STASH_A.OUT'), 5)
        self.assertFalse(sim.tick())

    def test_immediates(self):
        for value in (1, 0, 4095, -2048, -1, 4096, 1 << 63):
            with self.subTest(value=value):
                sim = machine(f'CONST -> STASH_A [imm={value}]')
                self.assertEqual(result(sim, 'STASH_A.OUT'), value & MASK)
        five = 'CONST -> ARITH_A.LHS, CONST -> ARITH_A.RHS, CONST -> CMP.LHS, CONST -> CMP.RHS, CONST -> STASH_A [imm=9000]'
        self.assertEqual(result(machine(five), 'STASH_A.OUT'), 9000)

    def test_daisy_chain_and_shared_generation(self):
        sim = machine('''CONST -> ARITH_A.LHS, CONST -> ARITH_A.RHS [imm=7]
ARITH_A.ADD -> STASH_A, ARITH_A.SUB -> STASH_B, ARITH_A.ADD -> STASH_C
''')
        self.assertEqual(result(sim, 'STASH_A.OUT'), 14)
        self.assertEqual(result(sim, 'STASH_B.OUT'), 0)
        self.assertEqual(result(sim, 'STASH_C.OUT'), 14)
        sim = machine('''CONST -> ARITH_A.LHS, CONST -> ARITH_A.RHS, ARITH_A.ADD -> STASH_A [imm=9]''')
        self.assertEqual(result(sim, 'STASH_A.OUT'), 18)
        self.assertEqual(sim.ticks, 3)
        self.assertFalse(sim.state.sources[4].ready({}))

    def test_output_retirement_and_staging_across_ticks(self):
        sim = Simulator(assemble('''CONST -> ARITH_A.LHS, CONST -> ARITH_A.RHS [imm=8]
ARITH_A.ADD -> ARITH_B.LHS, ARITH_A.SUB -> STASH_A, ARITH_A.ADD -> STASH_B [sync]
''' + HALT))
        sim.tick()
        # ARITH_B cannot drain its full LHS queue without an RHS token.
        queue = sim.state.sinks[3]
        for _ in range(DEPTH):
            queue.write(99)
        sim.instruction = sim.stream.fetch()
        sim.instruction.synchronized = False
        sim.tick()
        self.assertFalse(sim.instruction.finished)
        queue.values.clear()
        sim.run()
        self.assertEqual(list(queue.values), [16])
        self.assertEqual(result(sim, 'STASH_A.OUT'), 0)
        self.assertEqual(result(sim, 'STASH_B.OUT'), 16)

    def test_predication(self):
        sim = machine('''ZERO -> COND
CONST -> STASH_A, ARITH_A.ADD -> STASH_B [pred, imm=99]
CONST -> COND
CONST -> STASH_A [pred, imm=7]''')
        self.assertEqual(result(sim, 'STASH_A.OUT'), 7)
        self.assertFalse(sim.state.sinks[62].values)
        sim = Simulator(assemble('CONST -> PC [pred, imm=-1]'))
        with self.assertRaisesRegex(SimulationError, 'stalled'):
            sim.run()

    def test_call_return_and_deferred_halt(self):
        sim = machine('''PC_NEXT -> STACK_A, CONST -> PC [imm=subroutine]
CONST -> PC [imm=-1]
subroutine: CONST -> STASH_A [imm=23]
STACK_A -> PC''')
        self.assertEqual(result(sim, 'STASH_A.OUT'), 23)
        sim = machine('''CONST -> ARITH_A.LHS, CONST -> ARITH_A.RHS [imm=3]
CONST -> PC, ARITH_A.ADD -> STASH_A [imm=-1]''')
        self.assertEqual(result(sim, 'STASH_A.OUT'), 6)
        self.assertEqual(sim.ticks, 2)

    def test_stack(self):
        sim = machine('''CONST -> STACK_A [imm=2]
CONST -> STACK_A [imm=3]
STACK_A -> STASH_A
STACK_A -> STASH_B''')
        self.assertEqual(result(sim, 'STASH_A.OUT'), 3)
        self.assertEqual(result(sim, 'STASH_B.OUT'), 2)

    def test_memory_program(self):
        sim = machine('''CONST -> MEM.READ, CONST -> MEM.WRITE [imm=data]
MEM -> ARITH_A.LHS, CONST -> ARITH_A.RHS
ARITH_A.ADD -> MEM.CHUNK, ZERO -> MEM.MASK
CONST -> PC [imm=-1]
data: .word 123''')
        self.assertEqual(int.from_bytes(sim.memory[-16:-8], 'little'), 124)

    def test_memory_requests_preserve_order_while_busy(self):
        sim = machine('''CONST -> MEM.READ [imm=data]
CONST -> MEM.WRITE [imm=data]
CONST -> MEM.CHUNK, ZERO -> MEM.MASK [imm=456]
CONST -> MEM.READ [imm=data]
MEM -> STASH_A
MEM -> STASH_B
CONST -> PC [imm=-1]
data: .word 123''')
        self.assertEqual(result(sim, 'STASH_A.OUT'), 123)
        self.assertEqual(result(sim, 'STASH_B.OUT'), 456)

    def test_typed_memory_swap(self):
        source = '''CONST -> PACK.ADDR, CONST -> UNPACK.ADDR [imm=259]
CONST -> PACK.TYPE, CONST -> UNPACK.TYPE
CONST -> PACK.VALUE [imm=0x1fe]
PACK.ADDR -> MEM.READ, PACK.ADDR -> MEM.WRITE, PACK.CHUNK -> MEM.CHUNK, PACK.MASK -> MEM.MASK [sync]
MEM -> UNPACK.CHUNK
UNPACK -> STASH_A'''
        sim = Simulator(assemble(source + HALT), memory_size=264)
        sim.memory[256:264] = bytes([1, 2, 3, 0xab, 5, 6, 7, 8])
        sim.run()
        self.assertEqual(result(sim, 'STASH_A.OUT'), (-85) & MASK)
        self.assertEqual(sim.memory[256:264], bytes([1, 2, 3, 0xfe, 5, 6, 7, 8]))

    def test_memory_types_and_faults(self):
        for type_code, width in enumerate((1, 1, 2, 2, 4, 4, 8, 8)):
            with self.subTest(type_code=type_code):
                address = 16 - width
                value = 1 << (width * 8 - 1)
                chunk = 1 << 63
                self.assertEqual(evaluate(units.PackUnit, [address, type_code, value]),
                                 {'ADDR': address, 'CHUNK': chunk, 'MASK': (1 << (8 - width)) - 1})
                expected = -value if type_code & 1 else value
                self.assertEqual(evaluate(units.UnpackUnit, [address, type_code, chunk]), {'VALUE': expected})
        for unit_class, values in [(units.MemoryUnit, [0, None]), (units.MemoryUnit, [None, (0, 0, 0)]),
                                   (units.PackUnit, [1, 2, 0]), (units.UnpackUnit, [0, 8, 0])]:
            with self.subTest(unit=unit_class.__name__), self.assertRaises(SimulationError):
                evaluate(unit_class, values)

    def test_arithmetic_units(self):
        cases = [
            (units.ArithmeticUnit, [MASK, 1], {'ADD': 0, 'SUB': MASK - 1}),
            (units.LogicUnit, [5, 3], {'AND': 1, 'OR': 7, 'XOR': 6}),
            (units.ShiftUnit, [1 << 63, 1], {'LSL': 0, 'LSR': 1 << 62, 'ASR': 3 << 62, 'ROL': 1, 'ROR': 1 << 62}),
            (units.CompareUnit, [MASK, 1], {'EQ': 0, 'NE': 1, 'LT': 0, 'LTS': 1, 'LTE': 0, 'LTES': 1}),
            (units.MultiplyUnit, [MASK, 2], {'LO': MASK - 1, 'HI': 1}),
            (units.SignedMultiplyUnit, [MASK, 2], {'LO': MASK - 1, 'HI': MASK}),
            (units.DivideUnit, [7, 3], {'REM': 1, 'QUO': 2}),
            (units.SignedDivideUnit, [(-7) & MASK, 3], {'REM': MASK, 'QUO': MASK - 1}),
            (units.MaskUnit, [64], {'MASK': MASK, 'BIT': 0}),
            (units.UnaryUnit, [1], {'NEG': MASK, 'NOT': MASK - 1, 'BSW': 1 << 56}),
            (units.BitCountUnit, [0], {'POP': 0, 'CLZ': 64, 'CTZ': 64}),
            (units.SelectUnit, [0, 4, 5], {'OUT': 5}),
            (units.SwizzleUnit, [0x0807060504030201, sum((7 - i) << (3 * i) for i in range(8))],
             {'VALUE': 0x0102030405060708}),
        ]
        for unit_class, values, expected in cases:
            with self.subTest(unit=unit_class.__name__):
                actual = {name: int(value) & MASK for name, value in evaluate(unit_class, values).items()}
                self.assertEqual(actual, expected)
        with self.assertRaisesRegex(SimulationError, 'division by zero'):
            evaluate(units.DivideUnit, [1, 0])

    def test_cmp_ne_and_eq_share_a_generation(self):
        for rhs, eq, ne in [('ZERO', 0, 1), ('CONST', 1, 0)]:
            with self.subTest(rhs=rhs):
                sim = machine(f'''CONST -> CMP.LHS, {rhs} -> CMP.RHS
CMP.EQ -> STASH_A, CMP.NE -> STASH_B [sync]''')
                self.assertEqual(result(sim, 'STASH_A.OUT'), eq)
                self.assertEqual(result(sim, 'STASH_B.OUT'), ne)

    def test_latency_and_independent_units(self):
        source = ('CONST -> MUL.LHS, CONST -> MUL.RHS, '
                  'CONST -> ARITH_A.LHS, CONST -> ARITH_A.RHS [imm=3]\n'
                  'MUL.LO -> STASH_A\n')
        sim = Simulator(assemble(source + HALT), latencies={'MUL': 7})
        sim.tick()
        self.assertTrue(sim.state.sources[3].ready({}))  # ARITH completed independently.
        self.assertFalse(sim.state.sources[28].ready({}))
        sim.run()
        self.assertEqual(result(sim, 'STASH_A.OUT'), 9)
        self.assertEqual(sim.ticks, 9)
        fast = Simulator(assemble(source + HALT), latencies={'MUL': 1})
        fast.run()
        self.assertEqual(fast.ticks, 3)
        self.assertEqual(result(fast, 'STASH_A.OUT'), 9)

    def test_latency_keeps_one_operation_in_flight(self):
        sim = Simulator(b'', latencies={'MUL': 3})
        unit = next(unit for unit in sim.units if type(unit) is units.MultiplyUnit)
        lhs, rhs = unit.inputs.values()
        lhs.write(2)
        rhs.write(3)
        unit.execute()
        self.assertTrue(unit.busy)
        self.assertFalse(unit.results)
        lhs.write(4)
        rhs.write(5)
        unit.execute()
        self.assertEqual(list(lhs.values), [4])
        self.assertFalse(unit.results)
        unit.execute()
        self.assertFalse(unit.busy)
        self.assertEqual(unit.results[0], {'LO': 6, 'HI': 0})
        self.assertEqual(list(lhs.values), [4])
        for _ in range(3):
            unit.execute()
        self.assertEqual(unit.results[1], {'LO': 20, 'HI': 0})
        while len(unit.results) < DEPTH:
            unit.results.append({'LO': 0, 'HI': 0})
        lhs.write(6)
        rhs.write(7)
        self.assertFalse(unit.execute())
        self.assertEqual(list(lhs.values), [6])
        self.assertFalse(unit.busy)

    def test_memory_latency_and_halt_drain(self):
        sim = Simulator(assemble(HALT), memory_size=32, latencies={'MEM': 3})
        sim.state.sinks[35].write(16)
        sim.state.sinks[36].write(123)
        sim.state.sinks[37].write(0)
        sim.tick()
        self.assertFalse(sim.halted)
        self.assertEqual(sim.memory[16:24], b'\0' * 8)
        sim.tick()
        self.assertEqual(sim.memory[16:24], b'\0' * 8)
        sim.tick()
        self.assertTrue(sim.halted)
        self.assertEqual(int.from_bytes(sim.memory[16:24], 'little'), 123)
        # MEM samples the read address at issue and reads memory at completion.
        mem = sim.state.sources[38].unit
        mem.inputs['READ'].write(16)
        mem.execute()
        self.assertFalse(mem.results)
        sim.memory[16] = 42
        mem.execute()
        self.assertFalse(mem.results)
        mem.execute()
        self.assertEqual(mem.results[0]['CHUNK'], 42)

    def test_latency_configuration(self):
        sim = Simulator(b'', latencies={'ARITH': 2, 'ARITH_A': 5, 'MEM': 6})
        self.assertEqual(sim.state.sources[3].unit.latency, 5)
        self.assertEqual(sim.state.sources[5].unit.latency, 2)
        self.assertEqual(sim.state.sources[28].unit.latency, 2)
        self.assertEqual(sim.state.sources[30].unit.latency, 2)
        self.assertEqual(sim.state.sources[32].unit.latency, 7)
        self.assertEqual(sim.state.sources[38].unit.latency, 6)
        for overrides in ({'MUL': 0}, {'MUL': -1}, {'MUL': 1.5}, {'MUL': True}, {'TYPO': 3}):
            with self.subTest(overrides=overrides), self.assertRaises(SimulationError):
                Simulator(b'', latencies=overrides)
        self.assertEqual(units.parse_latency('MUL=5'), ('MUL', 5))
        for argument in ('MUL=0', 'MUL=-1', 'MUL=slow', 'MUL', '=3'):
            with self.subTest(argument=argument), self.assertRaises(units.argparse.ArgumentTypeError):
                units.parse_latency(argument)

    def test_errors_and_limits(self):
        for index in (59, 60):
            word = (63 << 6) | index  # Reserved source routed to DISCARD.
            with self.subTest(index=index), self.assertRaisesRegex(SimulationError, 'reserved source'):
                Simulator(word.to_bytes(8, 'little')).tick()
        with self.assertRaisesRegex(SimulationError, 'reserved sink'):
            Simulator((26 << 6).to_bytes(8, 'little')).tick()
        for binary, message in [(b'\0' * 7, 'memory access'),
                                (assemble('CONST -> PC [imm=3]'), 'unaligned'),
                                (assemble('CONST -> PC [imm=0]'), 'tick limit'),
                                (assemble('ARITH_A.ADD -> STASH_A'), 'stalled')]:
            with self.subTest(message=message), self.assertRaisesRegex(SimulationError, message):
                Simulator(binary).run(max_ticks=20)
        extended = assemble('CONST -> STASH_A [imm=9000]')[:8]
        with self.assertRaisesRegex(SimulationError, 'memory access'):
            Simulator(extended).run()
        with self.assertRaisesRegex(SimulationError, 'smaller than image'):
            Simulator(b'12345678', 4)
        self.assertEqual(len(Simulator(assemble(HALT), 128).memory), 128)

    def test_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'program.bin'
            output = Path(directory) / 'result.bin'
            image.write_bytes(assemble(HALT))
            process = subprocess.run([sys.executable, str(ROOT / 'src/simulator/simulator.py'),
                                      str(image), '--latency', 'MUL=5', '--latency', 'MEM=8',
                                      '--dump-memory', str(output)], capture_output=True, text=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertIn('halted after 1 ticks', process.stdout)
            self.assertEqual(output.read_bytes(), image.read_bytes())


if __name__ == '__main__':
    unittest.main()
