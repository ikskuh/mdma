"""Compile QBE fixtures and check their architectural results."""

import re
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE.parent))
import test_behavior


class QbeTest(unittest.TestCase):
    def check_fixture(self, path):
        header = path.read_text().splitlines()
        error = re.fullmatch(r'# expect error (.+)', header[0]) if header else None
        libraries = sorted(path.parent.glob('*.lib.ssa'))
        result = subprocess.run([ROOT / 'build/qbe-mdma', path, *libraries],
                                capture_output=True, text=True, timeout=30)
        if error:
            self.assertNotEqual(result.returncode, 0, path.name)
            self.assertIn(error[1], result.stderr)
            self.assertEqual(result.stdout, '')
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            test_behavior.BehaviorTest().check_fixture(
                path, assembly=result.stdout, extra_memory=65536, max_ticks=1000000)


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
