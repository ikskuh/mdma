"""Check the RTL runner's exported counters and existing result interface."""

import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src/qbe'))
from coremark import run as coremark


class RtlProfileTest(unittest.TestCase):
    def test_counters_and_legacy_result(self):
        output = ('PROFILE clocks=100 cache_lookups=12 cache_hits=9 cache_misses=3\n'
                  'PROFILE retired=25 const_stall=10 instruction_stall=20 redirect_stall=5 '
                  'execute_wait=30 decode_bubble=10\n'
                  'PROFILE const_stall_events=2 instruction_stall_events=4\n'
                  'COREMARK 100 120 0001 0002 0003 0004\n')
        completed = subprocess.CompletedProcess([], 0, stdout=output)
        for collect in (False, True):
            with self.subTest(collect=collect), tempfile.TemporaryDirectory() as directory:
                profile = {} if collect else None
                stdout = io.StringIO()
                with patch.object(coremark.subprocess, 'run', return_value=completed), contextlib.redirect_stdout(stdout):
                    result = coremark.ecp5(Path(directory), bytes(8), {'result': 0}, 0, 8,
                                           executable=Path('/unused'), profile=profile)
                self.assertEqual(result, (100, 120, [1, 2, 3, 4]))
                self.assertIn('0.25000000 instructions/clock', stdout.getvalue())
                if collect:
                    self.assertEqual(profile['cache_misses'], 3)
                    self.assertEqual(profile['const_stall_events'], 2)
                    self.assertEqual(profile['instruction_stall'], 20)
                    self.assertEqual(sum(profile[key] for key in ('retired', 'const_stall', 'instruction_stall',
                                                                  'redirect_stall', 'execute_wait', 'decode_bubble')),
                                     profile['clocks'])


if __name__ == '__main__':
    unittest.main()
