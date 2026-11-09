"""Compile QBE fixtures and check their architectural results."""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE.parent))
import test_behavior
from mdma_asm import parse_asm

PROFILES = ROOT / 'src/qbe/profiles'
MODES = (('--no-schedule',), (), ('--schedule', PROFILES / 'simulator.conf'),
         ('--schedule', PROFILES / 'ecp5.conf'))


def compile_fixture(path, options):
    libraries = sorted(path.parent.glob('*.lib.ssa'))
    return subprocess.run([ROOT / 'build/qbe-mdma', *options, path, *libraries],
                          capture_output=True, text=True, timeout=30)


class QbeTest(unittest.TestCase):
    def check_fixture(self, path):
        header = path.read_text().splitlines()
        error = re.fullmatch(r'# expect error (.+)', header[0]) if header else None
        for options in MODES:
            with self.subTest(options=options):
                result = compile_fixture(path, options)
                if error:
                    self.assertNotEqual(result.returncode, 0, path.name)
                    self.assertIn(error[1], result.stderr)
                    self.assertEqual(result.stdout, '')
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    test_behavior.BehaviorTest().check_fixture(
                        path, assembly=result.stdout, extra_memory=65536, max_ticks=1000000)

    def test_profiles_change_packing(self):
        path = HERE / 'schedule_interleave.ssa'
        sim, ecp5 = [compile_fixture(path, mode).stdout for mode in MODES[2:]]
        self.assertNotEqual(sim, ecp5)
        for asm in (sim, ecp5):
            bundles = [line for line in parse_asm(asm) if len(line.ops) == 5]
            self.assertTrue(any(len({move.dst.split('.')[0] for move in line.ops}) >= 3
                                for line in bundles))
            self.assertRegex(asm, r'STASH_([A-D])\.OUT -> STASH_\1\.IN')
            self.assertIn('MUL.LO -> ARITH_', asm)
        self.assertEqual(compile_fixture(path, ()).stdout, ecp5)

    def test_stack_order_is_a_target_capability(self):
        path = HERE / 'schedule_stack.ssa'
        nested = compile_fixture(path, MODES[3]).stdout
        self.assertGreater(self.stack_depth(nested), 1)
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / 'portable.conf'
            profile.write_text((PROFILES / 'ecp5.conf').read_text().replace(
                'stack_push_ordered yes\n', ''))
            result = compile_fixture(path, ('--schedule', profile))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.stack_depth(result.stdout), 1)
        image, expected, fault = test_behavior.load_fixture(path, result.stdout)
        self.assertIsNone(fault)
        sim = test_behavior.Simulator(image, len(image) + 65536,
                                     latencies={'STACK': 6, 'STASH': 3, 'MUL': 11})
        sim.run()
        address, value = expected['__mdma_result']
        self.assertEqual(int.from_bytes(sim.memory[address:address + 8], 'little'), value)

    @staticmethod
    def stack_depth(assembly):
        depth = dict.fromkeys(('STACK_A', 'STACK_B'), 0)
        peak = 0
        for line in parse_asm(assembly):
            for bank in depth:
                depth[bank] -= any(move.src == bank + '.TOP' for move in line.ops)
                depth[bank] += any(move.dst == bank + '.PUSH' for move in line.ops)
                peak = max(peak, depth[bank])
        return peak

    def test_bad_profiles(self):
        path = HERE / 'schedule_interleave.ssa'
        profile = (PROFILES / 'ecp5.conf').read_text()
        for old, new, error in (
            ('ARITH_A 5 1', 'ARITH_A 0 1', 'expected UNIT LATENCY ISSUE_INTERVAL'),
            ('ARITH_A 5 1', 'ARITH_A 5 1\nARITH_A 5 1', 'duplicate unit ARITH_A'),
            ('ARITH_A 5 1', 'ARITH_X 5 1', 'unknown unit ARITH_X'),
            ('ARITH_A 5 1', '', 'missing unit ARITH_A'),
        ):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory:
                bad = Path(directory) / 'bad.conf'
                bad.write_text(profile.replace(old, new))
                result = compile_fixture(path, ('--schedule', bad))
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(result.stderr, r'bad\.conf:\d+: ' + error)


def fixture_test(path):
    def test(self):
        self.check_fixture(path)
    return test


paths = sorted(path for path in HERE.rglob('*.ssa') if not path.name.endswith('.lib.ssa'))
if not paths:
    raise SystemExit('no QBE fixtures found')
for path in paths:
    name = 'test_' + '_'.join(path.relative_to(HERE).with_suffix('').parts).replace('-', '_')
    if hasattr(QbeTest, name):
        raise ValueError(f'duplicate QBE fixture name {name!r}')
    setattr(QbeTest, name, fixture_test(path))


if __name__ == '__main__':
    unittest.main(verbosity=2)
