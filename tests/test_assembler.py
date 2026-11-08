"""Run with python -m unittest discover -s tests."""
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src' / 'assembler'))
from mdma_asm import assemble
from mdma import SINK_BY_NAME, SOURCE_BY_NAME, FunctionUnitInstance


def words(source):
    data = assemble(source)
    return [int.from_bytes(data[i:i + 8], 'little') for i in range(0, len(data), 8)]


def decode(word):
    result = []
    dst = -1
    for i in range(4 if (word >> 60) & 3 in (2, 3) else 5):
        pair = (word >> (12 * i)) & 4095
        dst = min(63, dst + (pair >> 6) + 1)
        result.append((pair & 63, dst))
    return result


class AssemblerTest(unittest.TestCase):
    def test_program_and_layout(self):
        source = '''start: CONST -> PC [imm=end, pred, sync]
.word start, -1, 0x123456789abcdef0
end: ZERO -> STASH_A
CONST -> PC [imm=start]
'''
        image = words(source)
        self.assertEqual(len(image), 8)
        self.assertEqual(image[0] >> 60, 13)
        self.assertEqual(image[1:5], [40, 0, (1 << 64) - 1, 0x123456789abcdef0])
        self.assertEqual(decode(image[5]), [(0, 46)] + [(0, 63)] * 4)
        self.assertEqual(image[7], 0)

    def test_immediates_and_moves(self):
        for value, mode in [(1, 0), (0, 2), (4095, 2), (-1, 3), (-2048, 3),
                            (4096, 1), (-2049, 1), ((1 << 64) - 1, 1)]:
            with self.subTest(value=value):
                image = words(f'CONST -> PC [imm={value}]')
                self.assertEqual((image[0] >> 60) & 3, mode)
                self.assertEqual(len(image), 2 if mode == 1 else 1)
                if mode in (2, 3):
                    self.assertEqual((image[0] >> 48) & 4095, value & 4095)
                if mode == 1:
                    self.assertEqual(image[1], value & ((1 << 64) - 1))
        source = 'ZERO -> STASH_A, CONST -> PC, ARITH_A.ADD -> CMP.LHS'
        self.assertEqual(decode(words(source)[0])[:3], [(1, 0), (3, 13), (0, 46)])
        five = 'ZERO -> PC, ZERO -> ARITH_A.LHS, ZERO -> ARITH_A.RHS, ZERO -> CMP.LHS, ZERO -> COND'
        self.assertEqual(len(words(five + ' [imm=2]')), 2)
        self.assertEqual(decode(words('ZERO -> DISCARD, CONST -> DISCARD')[0])[:2], [(0, 63), (1, 63)])

    def test_names(self):
        for table in (SINK_BY_NAME, SOURCE_BY_NAME):
            self.assertEqual(len(table), 64)
            for name, fifo in table.items():
                self.assertIsInstance(fifo.unit, FunctionUnitInstance)
                self.assertEqual(name, f"{fifo.unit}.{fifo.name}")
        for short, full in (('ZERO -> STASH_A', 'CPU.ZERO -> STASH_A.IN'),
                            ('MEM -> STASH_A', 'MEM.CHUNK -> STASH_A.IN'),
                            ('UNPACK -> STASH_A', 'UNPACK.VALUE -> STASH_A.IN'),
                            ('CONST -> PC', 'CPU.CONST -> CPU.PC')):
            self.assertEqual(assemble(short), assemble(full))
        self.assertNotIn('STASH_A', SINK_BY_NAME)
        self.assertNotIn('ZERO', SOURCE_BY_NAME)
        with self.assertRaisesRegex(ValueError, 'unknown source'):
            assemble('ARITH_A -> PC')

    def test_memory_port_encoding(self):
        sinks = ('MEM.READ', 'MEM.WRITE', 'MEM.CHUNK', 'MEM.MASK',
                 'PACK.ADDR', 'PACK.TYPE', 'PACK.VALUE', 'UNPACK.ADDR', 'UNPACK.TYPE', 'UNPACK.CHUNK')
        for index, port in enumerate(sinks, 34):
            self.assertEqual(decode(words(f'ZERO -> {port}')[0])[0], (0, index))
        for index, port in [(38, 'MEM.CHUNK'), (39, 'PACK.CHUNK'), (40, 'PACK.MASK'),
                            (41, 'UNPACK.VALUE'), (57, 'PACK.ADDR')]:
            self.assertEqual(decode(words(f'{port} -> DISCARD')[0])[0], (index, 63))
        for move in ('LOAD -> DISCARD', 'ZERO -> STORE.ADDR', 'ZERO -> PACK.SIZE',
                     'EXTRACT -> DISCARD', 'EXT.SX8 -> DISCARD', 'ZERO -> EXT'):
            with self.subTest(move=move), self.assertRaisesRegex(ValueError, 'unknown source|unknown sink'):
                assemble(move)

    def test_errors(self):
        for source in ('a:\na:', '.word', '.word 1,', '.word missing', '.word 18446744073709551616',
                       'ZERO -> PC [imm=-9223372036854775809]', 'ZERO -> PC [pred, pred]',
                       'ZERO -> PC [imm=1', 'ZERO -> PC [wat]', 'ZERO -> PC [imm]', 'ZERO -> PC [imm=]', 'ZERO -> PC,',
                       'bad label:', 'BAD -> PC', 'ZERO -> BAD', 'ZERO -> PC, CONST -> PC',
                       ','.join(['ZERO -> DISCARD'] * 6)):
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, r'line \d+:'):
                assemble(source)

    def test_stdin_cli(self):
        script = Path(__file__).resolve().parents[1] / 'src/assembler/mdma_asm.py'
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'out.bin'
            result = subprocess.run([sys.executable, str(script), '-', '-o', str(output)],
                                    input='.word 1', text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_bytes(), b'\x01' + b'\0' * 7)


if __name__ == '__main__':
    unittest.main()
