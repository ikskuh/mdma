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
from mdma_asm import assemble, parse_asm

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
            self.assertRegex(asm, r'STASH_([A-D])\.OUT -> STASH_\1\.IN')
            self.assertIn('MUL.LO -> ARITH_', asm)
        for asm, expected in ((sim, True), (ecp5, False)):
            jointly_issued = any(
                {'ARITH_A.LHS', 'LOGIC_A.LHS'} <= {move.dst for move in line.ops}
                for line in parse_asm(asm))
            self.assertEqual(jointly_issued, expected)
        self.assertEqual(compile_fixture(path, ()).stdout, ecp5)

    def test_queued_fu_results_retire_in_order(self):
        result = compile_fixture(HERE / 'schedule_fifo_order.ssa', ())
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = list(parse_asm(result.stdout))
        issues = [n for n, line in enumerate(lines) if any(m.dst == 'MUL.LHS' for m in line.ops)]
        reads = [(n, m.dst) for n, line in enumerate(lines) for m in line.ops if m.src == 'MUL.LO']
        self.assertEqual(len(issues), 2)
        self.assertEqual([dst for _, dst in reads], ['ARITH_A.LHS', 'LOGIC_A.LHS'])
        self.assertLess(issues[-1], reads[0][0])

    def test_sum_loop_uses_fifo_feedback(self):
        result = compile_fixture(HERE / 'fifo_sum.ssa', ())
        self.assertEqual(result.returncode, 0, result.stderr)
        sum_label = '__mdma_g1_73756d5f746f'
        asm = result.stdout.split(sum_label + ':\n', 1)[1].split('__mdma_g0_6d61696e:', 1)[0]
        lines = [line for line in parse_asm(asm) if line.ops]
        predicates = [line for line in lines if line.predicate]
        self.assertEqual(len(predicates), 1)
        back_edge, = predicates
        loop = sum_label + '_countdown'
        self.assertEqual(back_edge.relative, loop)
        self.assertFalse(any(line.synchronized for line in lines))
        branch = lines.index(back_edge)
        self.assertEqual({(m.src, m.dst) for m in back_edge.ops},
                         {('ARITH_A.ADD', 'ARITH_A.LHS'), ('CONST', 'PC_REL')})
        self.assertEqual({m.dst for m in lines[branch - 1].ops if m.src == 'ARITH_B.SUB'},
                         {'COND', 'ARITH_B.LHS', 'ARITH_A.RHS'})
        self.assertEqual([line.immediate for line in lines
                          if any(m.dst == 'UNPACK.TYPE' for m in line.ops)], ['4'])
        self.assertTrue(any({m.src for m in line.ops} == {'UNPACK.VALUE', 'STACK_B.TOP'}
                            for line in lines))

        # A call target label cannot share CONST with a different argument.
        main = result.stdout.split('__mdma_g0_6d61696e:', 1)[1]
        call_lines = [line for line in parse_asm(main) if line.ops]
        for n, line in enumerate(call_lines):
            if line.immediate == '0xa':
                self.assertFalse(any(m.dst in ('PC', 'CPU.PC', 'PC_REL', 'CPU.PC_REL') for m in line.ops))
                self.assertEqual(call_lines[n + 1].relative, sum_label)
                break
        else:
            self.fail('missing literal argument 10')

    def test_compute_fanout_packs_reads_of_the_same_result(self):
        result = compile_fixture(HERE / 'schedule_fanout.ssa', ())
        self.assertEqual(result.returncode, 0, result.stderr)
        reads = [[m.dst for m in line.ops if m.src == 'MUL.LO']
                 for line in parse_asm(result.stdout)]
        self.assertEqual([r for r in reads if r], [['ARITH_A.LHS', 'LOGIC_A.LHS']])

    def test_inline_preserves_word_argument_width(self):
        path = HERE / 'inline_word.ssa'
        result = compile_fixture(path, ())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('rel=__mdma_g1_776964656e', result.stdout)
        test_behavior.BehaviorTest().check_fixture(path, assembly=result.stdout, extra_memory=65536)

    def test_call_alignment_uses_one_read_when_proven(self):
        path = HERE / 'call_alignment.ssa'
        result = compile_fixture(path, ())
        self.assertEqual(result.returncode, 0, result.stderr)
        for name, reads in (('aligned_read', 1), ('mixed_read', 2), ('escaped_read', 2), ('aligned_loop', 1)):
            with self.subTest(name=name):
                label = '__mdma_g1_' + name.encode().hex()
                body = result.stdout.split(label + ':\n', 1)[1]
                body = re.split(r'^__mdma_g[01]_[0-9a-f]+:\n', body, maxsplit=1, flags=re.MULTILINE)[0]
                self.assertEqual(body.count(' -> MEM.READ'), reads)

    def test_alignment_guard_selects_two_fifo_bodies(self):
        result = compile_fixture(HERE / 'alignment_guard.ssa', ())
        self.assertEqual(result.returncode, 0, result.stderr)
        label = '__mdma_g1_' + 'sum_pairs'.encode().hex()
        guard, bodies = result.stdout.split(label + '_aligned:\n', 1)
        aligned, generic = bodies.split(label + '_generic:\n', 1)
        generic = generic.split('__mdma_g0_6d61696e:\n', 1)[0]
        self.assertIn('[pred, rel=' + label + '_generic]', guard)
        self.assertEqual(aligned.count(' -> MEM.READ'), 2)
        self.assertEqual(generic.count(' -> MEM.READ'), 4)

    def test_known_branches_remove_only_proven_comparisons(self):
        result = compile_fixture(HERE / 'branch_facts.ssa', ())
        self.assertEqual(result.returncode, 0, result.stderr)
        for name, comparisons in (('word_bounds', 2), ('small_range', 2), ('state_domain', 0)):
            with self.subTest(name=name):
                label = '__mdma_g1_' + name.encode().hex()
                body = result.stdout.split(label + ':\n', 1)[1]
                body = re.split(r'^__mdma_g[01]_[0-9a-f]+:\n', body, maxsplit=1, flags=re.MULTILINE)[0]
                self.assertEqual(body.count(' -> CMP.LHS'), comparisons)

    def test_range_classifier_is_inlined(self):
        result = compile_fixture(HERE / 'range_boolean.ssa', MODES[2])
        self.assertEqual(result.returncode, 0, result.stderr)
        label = '__mdma_g1_' + 'digit'.encode().hex()
        body = result.stdout.split(label + ':\n', 1)[1]
        body = re.split(r'^__mdma_g[01]_[0-9a-f]+:\n', body, maxsplit=1, flags=re.MULTILINE)[0]
        self.assertEqual(body.count(' -> CMP.LHS'), 1)
        self.assertNotIn('[pred', body)
        self.assertNotIn('rel=' + label + ']', result.stdout)

    def test_independent_queue_rotations_share_a_pack(self):
        result = compile_fixture(HERE / 'call_alignment.ssa', MODES[2])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('STASH_A.OUT -> STASH_A.IN, STASH_B.OUT -> STASH_B.IN [sync]', result.stdout)

    def test_relative_calls_return_after_short_and_extended_packs(self):
        path = HERE / 'fifo_sum.ssa'
        result = compile_fixture(path, ())
        self.assertEqual(result.returncode, 0, result.stderr)
        assembly = result.stdout
        call = next(line for line in parse_asm(assembly) if line.ops)
        self.assertTrue(call.relative)
        self.assertTrue(any(move.src == 'PC_NEXT' and move.dst == 'STACK_B.PUSH' for move in call.ops))
        extended = assembly.replace(f'rel={call.relative}]', f'rel={call.relative}, imm_mode=extended]', 1)
        for source, expect_extended in ((assembly, False), (extended, True)):
            with self.subTest(extended=expect_extended):
                opcode = int.from_bytes(assemble(source)[:8], 'little')
                self.assertEqual((opcode >> 60) & 3 == 1, expect_extended)
                test_behavior.BehaviorTest().check_fixture(path, assembly=source, extra_memory=65536)

    def test_compute_edge_layouts(self):
        result = compile_fixture(HERE / 'fifo_fu_edges.ssa', ())
        self.assertEqual(result.returncode, 0, result.stderr)
        carry, join, mismatch = re.split(
            r'^__mdma_g[01]_[0-9a-f]+:\n', result.stdout, flags=re.MULTILINE)[1:4]
        self.assertNotRegex(carry, r'MUL.LO -> (STASH|STACK)')
        self.assertIn('MUL.LO -> LOGIC_A.LHS', carry)
        self.assertIn('MUL.LO -> ARITH_A.LHS', carry)
        self.assertIn('ARITH_A.ADD -> LOGIC_A.LHS', join)
        self.assertIn('MUL.LO -> STASH_', mismatch)
        self.assertIn('ARITH_A.ADD -> STASH_', mismatch)

    def test_countdown_feedback_with_delayed_units(self):
        path = HERE / 'fifo_countdown.ssa'
        result = compile_fixture(path, ())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('_countdown:'), 1)
        image, expected, fault = test_behavior.load_fixture(path, result.stdout)
        self.assertIsNone(fault)
        sim = test_behavior.Simulator(image, len(image) + 65536,
                                     latencies={'ARITH': 9, 'UNPACK': 6, 'STASH': 3})
        sim.run()
        address, value = expected['__mdma_result']
        self.assertEqual(int.from_bytes(sim.memory[address:address + 8], 'little'), value)

    def test_stack_order_is_required(self):
        path = HERE / 'schedule_stack.ssa'
        nested = compile_fixture(path, MODES[3]).stdout
        self.assertGreater(self.stack_depth(nested), 1)
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / 'legacy.conf'
            profile.write_text((PROFILES / 'ecp5.conf').read_text() + 'stack_push_ordered yes\n')
            result = compile_fixture(path, ('--schedule', profile))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, nested)
        image, expected, fault = test_behavior.load_fixture(path, result.stdout)
        self.assertIsNone(fault)
        sim = test_behavior.Simulator(image, len(image) + 65536,
                                     latencies={'STACK': 6, 'STASH': 3, 'MUL': 11})
        sim.run()
        address, value = expected['__mdma_result']
        self.assertEqual(int.from_bytes(sim.memory[address:address + 8], 'little'), value)

    def test_fifo_control_flow_uses_only_the_result_store(self):
        for name in ('fifo_sum', 'fifo_phi_cycle', 'fifo_pressure'):
            path = HERE / (name + '.ssa')
            for options in MODES[2:]:
                with self.subTest(fixture=name, options=options):
                    result = compile_fixture(path, options)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    memory = [line for line in parse_asm(result.stdout)
                              if any(move.src.startswith('MEM.') or move.dst.startswith('MEM.')
                                     for move in line.ops)]
                    self.assertEqual([line.immediate for line in memory], ['__mdma_result'])
                    self.assertIn('PC_NEXT -> STACK_B.PUSH', result.stdout)

    def test_fifo_argument_overflow(self):
        result = compile_fixture(HERE / 'fifo_overflow.ssa', ())
        self.assertEqual(result.returncode, 0, result.stderr)
        slots = re.findall(r'^__mdma_arg_(\d+): \.word', result.stdout, re.MULTILINE)
        self.assertEqual(slots, ['4', '5'])

    def test_recursive_fifo_calls_with_delayed_pushes(self):
        path = HERE / 'recursion.ssa'
        result = compile_fixture(path, ())
        self.assertEqual(result.returncode, 0, result.stderr)
        image, expected, fault = test_behavior.load_fixture(path, result.stdout)
        self.assertIsNone(fault)
        sim = test_behavior.Simulator(image, len(image) + 65536,
                                     latencies={'STACK': 6, 'STASH': 3})
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
        arith = next(row for row in profile.splitlines() if row.startswith('ARITH_A '))
        for old, new, error in (
            (arith, 'ARITH_A 0 1', 'expected UNIT LATENCY ISSUE_INTERVAL'),
            (arith, arith + '\n' + arith, 'duplicate unit ARITH_A'),
            (arith, arith.replace('ARITH_A', 'ARITH_X'), 'unknown unit ARITH_X'),
            (arith, '', 'missing unit ARITH_A'),
            (arith, 'stack_push_ordered no\n' + arith, 'expected stack_push_ordered yes'),
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
