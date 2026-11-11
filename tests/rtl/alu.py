"""Drive each ALU mode against results from the architectural simulator."""
from itertools import product
from pathlib import Path
import random
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src/gateware/alu'))
sys.path.insert(0, str(ROOT / 'src/simulator'))
from measure import DIVIDERS, Divider, divider_defaults, isa_units, isolated_top
from mdma import SOURCE_BY_NAME
from simulator import Simulator
from simulator_core import MASK, SimulationError

FAULTS = {'invalid_type': 1, 'misaligned_typed_address': 2, 'division_by_zero': 3}


def operands(unit):
    rng = random.Random(17)
    edges = (0, 1, 2, 63, 64, 65, 1 << 63, (1 << 63) - 1, MASK - 1, MASK)
    if unit.family in {'PACK', 'UNPACK'}:
        for lane, type_code in product(range(8), (*range(9), MASK)):
            yield (0xFEDCBA9876543210 + lane, type_code, rng.getrandbits(64))
    elif unit.family in {'SHIFT', 'MASK'}:
        for count in (*range(66), 1 << 63, MASK):
            yield (rng.getrandbits(64), count) if unit.family == 'SHIFT' else (count,)
    elif len(unit.sinks) == 2:
        yield from product(edges, repeat=2)
        if unit.family in {'DIV', 'DIVS'}:
            for bit in range(64):
                divisor = rng.randrange(1 << bit, 1 << (bit + 1))
                if unit.family == 'DIVS' and rng.randrange(2):
                    divisor = -divisor & MASK
                yield rng.getrandbits(64), divisor
    elif unit.family == 'BITCNT':
        yield (0,)
        yield (MASK,)
        yield from ((1 << bit,) for bit in range(64))
    else:
        for value in edges:
            yield (value,) + tuple(rng.getrandbits(64) for _ in unit.sinks[1:])
    for _ in range(128):
        values = tuple(rng.getrandbits(64) for _ in unit.sinks)
        if unit.family in {'PACK', 'UNPACK'}:
            values = (values[0], rng.randrange(8), values[2])
        if unit.family == 'SEL' and rng.randrange(2):
            values = (0, *values[1:])
        yield values


def encode(fields):
    value = bit = 0
    for field, width in fields:
        value |= (field & ((1 << width) - 1)) << bit
        bit += width
    return value


def reference_vectors(unit, reference):
    for inputs in operands(unit):
        try:
            expected = {key.lower(): value for key, value in reference.compute(*inputs).items()}
        except SimulationError as error:
            expected = {'fault': FAULTS[error.code]}
        lanes = [(expected.get(lane, 0) & MASK | (int(lane in expected) << 64), 65)
                 for lane in unit.sources]
        yield encode([(value, 64) for value in inputs] + lanes)


def run(work, top, unit, sources, defines=()):
    executable = work / 'sim'
    subprocess.run(['iverilog', '-g2012', '-Wall', '-s', top, '-o', executable,
                    '-I', unit.rtl[0].parent, *defines, *unit.rtl, *sources], check=True, cwd=work)
    subprocess.run(['vvp', executable], check=True, cwd=work)
    return executable


def test_fu(work, unit, reference, mode, divider=None):
    vectors = list(reference_vectors(unit, reference))
    (work / 'vectors.hex').write_text(''.join(f'{value:x}\n' for value in vectors))
    input_bits = sum(width for _, width in unit.inputs)
    output_bits = sum(width for _, width in unit.outputs)
    (work / 'dut.v').write_text(f"""
module mdma_alu_dut (
    input wire clk,
    input wire [{input_bits-1}:0] drive,
    output wire [{output_bits-1}:0] observed
);
    {unit.instantiate(mode, 'clk', 'drive', 'observed', divider)}
endmodule
""")
    if mode == 'pipelined':
        latency = (divider or divider_defaults(unit.family)[0]).latency
    else:
        latency = int(mode == 'registered')
    defines = [f'-DSINKS={len(unit.sinks)}', f'-DSOURCES={len(unit.sources)}',
               f'-DREQUESTS={len(vectors)}', f'-DLATENCY={latency}']
    executable = run(work, 'mdma_alu_tb', unit, ['dut.v', ROOT / 'tests/rtl/mdma_alu_tb.v'], defines)
    subprocess.run(['vvp', executable, '+timing'], check=True, cwd=work)


def test_scan(work, unit, registered):
    (work / 'top.v').write_text(isolated_top(unit, 'registered' if registered else 'passthrough'))
    input_bits = sum(width for _, width in unit.inputs)
    output_bits = sum(width for _, width in unit.outputs)
    lhs, rhs = 0x0123456789ABCDEF, 0x1122334455667788
    reset = encode([(1, 1)])
    request = encode([(0, 1), (lhs, 64), (1, 1), (rhs, 64), (1, 1), (3, 2)])
    expected = encode([(3, 2), (lhs + rhs, 64), (1, 1), (lhs - rhs, 64), (1, 1)])
    (work / 'scan_tb.v').write_text(f"""
module scan_tb;
    reg fu_clk = 0, scan_clk = 0, scan_in = 0, scan_load = 0;
    wire scan_out;
    reg [{output_bits-1}:0] result;
    mdma_alu_measure dut (fu_clk, scan_clk, scan_in, scan_load, scan_out);

    task scan_pulse;
        begin
            #1 scan_clk = 1;
            #1 scan_clk = 0;
        end
    endtask

    task fu_pulse;
        begin
            #1 fu_clk = 1;
            #1 fu_clk = 0;
        end
    endtask

    task load;
        input [{input_bits-1}:0] packet;
        begin
            for (integer bit_index = {input_bits-1}; bit_index >= 0; bit_index = bit_index - 1) begin
                scan_in = packet[bit_index];
                scan_pulse;
            end
        end
    endtask

    initial begin
        load({input_bits}'h{reset:x});
        repeat (2) fu_pulse;
        load({input_bits}'h{request:x});
        repeat ({3 if registered else 2}) fu_pulse;
        scan_load = 1;
        scan_pulse;
        scan_load = 0;
        for (integer bit_index = {output_bits-1}; bit_index >= 0; bit_index = bit_index - 1) begin
            result[bit_index] = scan_out;
            scan_pulse;
        end
        if (result !== {output_bits}'h{expected:x})
            $fatal(1, "scan readback %h", result);
        $finish;
    end
endmodule
""")
    run(work, 'scan_tb', unit, ['top.v', 'scan_tb.v'])


def main():
    units = isa_units()
    state = Simulator(b'').state
    with TemporaryDirectory(prefix='mdma-alu-test-') as directory:
        work = Path(directory)
        for name, unit in units.items():
            source = SOURCE_BY_NAME[f'{name}.{unit.sources[0].upper()}']
            reference = state.sources[source.index].unit
            modes = ['passthrough', 'registered']
            if unit.family in DIVIDERS:
                modes.append('pipelined')
            for mode in modes:
                test_fu(work, unit, reference, mode)
                if name == 'ARITH_A':
                    test_scan(work, unit, mode == 'registered')
            if unit.family in DIVIDERS:
                # Exercise the carry-select datapath and explicit sign input cut.
                alternative = Divider(tuple(range(4, 65, 4)), unit.family == 'DIVS', 16)
                test_fu(work, unit, reference, 'pipelined', alternative)
            print(f'{name}: {", ".join(modes)} passed', flush=True)


if __name__ == '__main__':
    main()
