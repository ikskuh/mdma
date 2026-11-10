"""Run portable assembly programs and check their final memory."""

import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src/assembler'))
sys.path.insert(0, str(ROOT / 'src/simulator'))
from mdma_asm import assemble_with_labels, resolve
from simulator import SimulationError, Simulator


HEADER = re.compile(r'#\s*expect\s+mem64\s+([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(\S+)')
FAULT_HEADER = re.compile(r'#\s*expect\s+fault\s+([a-z][a-z_0-9]*)')
FIXTURE_ROOT = Path(__file__).with_name('behavior')
FIXTURE_PATHS = sorted(FIXTURE_ROOT.rglob('*.mdma'))


def load_fixture(path, assembly=None):
    source = path.read_text(encoding='utf-8')
    image, labels = assemble_with_labels(source if assembly is None else assembly)
    expectations = {}
    fault = None
    in_header = True
    for number, raw in enumerate(source.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        if not line.startswith('#'):
            in_header = False
        if not re.match(r'#\s*expect\b', line):
            continue
        if not in_header:
            raise ValueError(f'line {number}: expectation must be in the leading comment header')
        fault_match = FAULT_HEADER.fullmatch(line)
        if fault_match:
            if fault is not None or expectations:
                raise ValueError(f'line {number}: fault must be the only expectation')
            fault = fault_match[1]
            continue
        match = HEADER.fullmatch(line)
        if not match:
            raise ValueError(f'line {number}: expected # expect mem64 <label> = <value> or # expect fault <code>')
        if fault is not None:
            raise ValueError(f'line {number}: fault must be the only expectation')
        label, value = match.groups()
        if label in expectations:
            raise ValueError(f'line {number}: duplicate expectation for {label!r}')
        if label not in labels:
            raise ValueError(f'line {number}: unknown label {label!r}')
        address = labels[label]
        if address + 8 > len(image):
            raise ValueError(f'line {number}: {label!r} has no word inside the image')
        try:
            expectations[label] = (address, resolve(value, {}))
        except ValueError as exc:
            raise ValueError(f'line {number}: {exc}') from exc
    if not expectations and fault is None:
        raise ValueError('missing expectation header')
    return image, expectations, fault


class BehaviorTest(unittest.TestCase):
    def test_fixtures_exist(self):
        self.assertTrue(FIXTURE_PATHS, 'tests/behavior contains no .mdma fixtures')

    def test_delayed_stack_fixtures(self):
        for name in ('20-units/stack_a_forward.mdma', '20-units/stack_a_replace.mdma',
                     '20-units/stack_b.mdma', '30-interactions/stack_exchange.mdma'):
            with self.subTest(fixture=name):
                self.check_fixture(FIXTURE_ROOT / name, latencies={'STACK': 6})

    def check_fixture(self, path, *, assembly=None, extra_memory=0, max_ticks=100000, latencies=None):
        try:
            image, expectations, fault = load_fixture(path, assembly)
        except (OSError, ValueError) as exc:
            self.fail(f'{path.name}: {exc}')
        sim = Simulator(image, memory_size=len(image) + extra_memory, latencies=latencies)
        try:
            sim.run(max_ticks=max_ticks)
        except SimulationError as exc:
            self.assertIsNotNone(fault, f'{path.name}: {exc}')
            self.assertEqual(exc.code, fault, f'{path.name}: expected fault {fault!r}, got {exc.code!r} ({exc})')
            return
        self.assertIsNone(fault, f'{path.name}: expected fault {fault!r}, but program halted')
        self.assertTrue(sim.halted, f'{path.name}: program did not halt')
        for label, (address, expected) in expectations.items():
            actual = int.from_bytes(sim.memory[address:address + 8], 'little')
            self.assertEqual(actual, expected,
                             f'{path.name}: {label} at {address:#x}, '
                             f'expected {expected:#018x}, actual {actual:#018x}')


def fixture_test(path):
    def test(self):
        self.check_fixture(path)
    return test


for path in FIXTURE_PATHS:
    fixture = path.relative_to(FIXTURE_ROOT).with_suffix('')
    name = 'test_' + '_'.join(fixture.parts).replace('-', '_')
    if hasattr(BehaviorTest, name):
        raise ValueError(f'duplicate fixture test name {name!r} for {fixture}')
    setattr(BehaviorTest, name, fixture_test(path))


class HarnessTest(unittest.TestCase):
    def test_rejects_bad_fixtures(self):
        program = 'CONST -> PC [imm=-1]\nresult: .word 42\n'
        cases = [
            ('', 'missing expectation'),
            ('# expect mem64 result 42', 'expected # expect mem64'),
            ('# expect mem64 missing = 42', 'unknown label'),
            ('# expect mem64 result = 0x10000000000000000', '64-bit range'),
            ('# expect mem64 end = 42', 'no word inside the image'),
            ('# expect mem64 result = 42\n# expect mem64 result = 42', 'duplicate expectation'),
            ('# expect fault stall\n# expect fault unaligned_pc', 'fault must be the only expectation'),
            ('# expect fault stall\n# expect mem64 result = 42', 'fault must be the only expectation'),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'bad.mdma'
            for header, message in cases:
                with self.subTest(header=header), self.assertRaisesRegex(ValueError, message):
                    path.write_text(f'{header}\n{program}end:\n', encoding='utf-8')
                    load_fixture(path)
            path.write_text(program + '# expect mem64 result = 42\n', encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'leading comment header'):
                load_fixture(path)

    def test_reports_execution_failures_and_mismatches(self):
        cases = [
            ('mem64 result = 42', 'CONST -> PC [imm=-1]',
             r'bad.mdma: result at 0x8, expected 0x0+2a, actual 0x0+01'),
            ('mem64 result = 42', 'ARITH_A.ADD -> DISCARD', r'bad.mdma: stalled'),
            ('mem64 result = 42', 'ZERO -> PC', r'bad.mdma: tick limit'),
            ('fault stall', 'CONST -> PC [imm=-1]', r"expected fault 'stall', but program halted"),
            ('fault stall', 'CONST -> PC [imm=3]', r"expected fault 'stall', got 'unaligned_pc'"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'bad.mdma'
            for expectation, program, message in cases:
                with self.subTest(program=program), self.assertRaisesRegex(AssertionError, message):
                    path.write_text(f'# expect {expectation}\n{program}\nresult: .word 1\n', encoding='utf-8')
                    BehaviorTest().check_fixture(path)
