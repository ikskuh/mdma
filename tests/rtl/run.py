"""Build the Icarus bench and compare assembly fixtures against the Python core."""

import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
from test_behavior import FIXTURE_PATHS, FIXTURE_ROOT, load_fixture
from mdma_asm import assemble_with_labels
from mdma import SINK_BY_INDEX, SOURCE_BY_INDEX
from simulator import Simulator, SimulationError
from simulator_core import INSTANCES
from rtl_runner import compile_bench, execute_image, prepare, write_bram_image, write_image

def benchmark_dispatch(build, bench):
    source = Path(__file__).with_name("five_wide.mdma").read_text()
    image, labels = assemble_with_labels(source)
    path = build / "five_wide.hex"
    write_image(image, path)
    result = subprocess.run(["vvp", str(bench), "+five_wide", f"+image={path}",
                             f"+words={len(image) // 8}", f"+dump={build / 'five_wide.dump'}",
                             f"+first_pc={labels['first_dispatch']}", f"+second_pc={labels['second_dispatch']}"],
                            check=True, capture_output=True, text=True, timeout=15)
    print("\n".join(line for line in result.stdout.splitlines() if line.startswith("BENCH ")))


def benchmark_alu(build, bench):
    for number, instance in enumerate(INSTANCES):
        if instance.unit.name in ('MUL', 'MULS', 'DIV', 'DIVS', 'MEM', 'STASH', 'STACK'):
            continue
        sinks = [port for port in SINK_BY_INDEX.values() if port.unit == instance]
        source = next(port for port in SOURCE_BY_INDEX.values() if port.unit == instance)
        produce = ', '.join(f'ZERO -> {port.full_name}' for port in sinks)
        consume = f'{source.full_name} -> DISCARD'
        assembly = '\n'.join(['producer:', produce, 'consumer:', consume] +
                             [produce] * 4 + [consume] * 4 + ['CONST -> PC [imm=producer]'])
        image, labels = assemble_with_labels(assembly)
        path = build / 'alu.hex'
        write_image(image, path)
        result = subprocess.run(
            ['vvp', str(bench), '+alu_latency', f'+image={path}', f'+words={len(image) // 8}',
             f'+dump={build / "alu.dump"}', f'+alu_producer={labels["producer"]}',
             f'+alu_consumer={labels["consumer"]}', f'+alu_unit={number}',
             f'+alu_source={source.index}', f'+alu_sink={max(port.index for port in sinks)}'],
            check=True, capture_output=True, text=True, timeout=15)
        row = re.search(r'^BENCH FU \d+ ready=(\d+) use=(\d+) burst=(\d+)/(\d+)$',
                        result.stdout, re.MULTILINE)
        if not row or int(row[3]) != 4:
            raise ValueError(f'{instance}: incomplete ALU benchmark: {result.stdout}')
        print(f'BENCH {instance}: dispatch to ready {row[1]}, dispatch to use {row[2]}, '
              f'burst {row[3]} requests in {int(row[4]) + 1} clocks')


def frontend_tests(build):
    for name in ('mdma_stream_tb', 'mdma_bram_tb', 'mdma_decode_tb'):
        bench = compile_bench(build, name)
        subprocess.run(['vvp', str(bench)], check=True, timeout=30)


def board_tests(build):
    image, labels = assemble_with_labels((ROOT / "examples/serial-echo.mdma").read_text())
    hex_path = build / "serial.hex"
    write_bram_image(image, hex_path)
    bench = compile_bench(build, "mdma_serial_tb")
    subprocess.run(["vvp", str(bench), f"+image={hex_path}", "+words=32768",
                    f"+cell={labels['cell'] // 8}", f"+readback={labels['readback'] // 8}"],
                   check=True, timeout=20)
    bounds_cases = (
        'CONST -> PC [imm=0x40000]',
        'CONST -> PC [imm=0x100000000]',
        'CONST -> MEM.READ [imm=0x100000000]\nMEM.CHUNK -> DISCARD',
        'CONST -> MEM.WRITE [imm=0x100000000]\nZERO -> MEM.CHUNK, ZERO -> MEM.MASK',
    )
    for source in bounds_cases:
        image, _ = assemble_with_labels(source + '\n')
        write_bram_image(image, hex_path)
        subprocess.run(['vvp', str(bench), f'+image={hex_path}', '+words=32768', '+expect_fault=3'],
                       check=True, timeout=20)


def compare(fixture, build, bench):
    image, expected_memory, expected_fault = load_fixture(fixture)
    actual_fault, ticks, clocks, actual_image, output = execute_image(image, build, bench)
    if actual_fault != expected_fault:
        raise ValueError(f"expected fault {expected_fault}, got {actual_fault} at tick {ticks}")
    software = Simulator(image)
    try:
        software.run()
        software_fault = None
    except SimulationError as error:
        software_fault = error.code
    if actual_fault != software_fault:
        raise ValueError(f"RTL fault {actual_fault} differs from Python fault {software_fault}")
    for label, (address, expected) in expected_memory.items():
        actual = int.from_bytes(actual_image[address:address + 8], "little")
        if actual != expected:
            raise ValueError(f"{label} at {address:#x}: expected {expected:#018x}, got {actual:#018x}")
    if actual_fault is None:
        if actual_image != software.memory:
            address = next(i for i, (a, b) in enumerate(zip(actual_image, software.memory)) if a != b)
            raise ValueError(f"RTL and Python final images differ at byte {address:#x}")
    latencies = [tuple(map(int, match)) for match in re.findall(r"^LATENCY (\d+) (\d+)$", output, re.MULTILINE)]
    return ticks, clocks, latencies


def main():
    if sys.argv[1:] == ["--benchmark"]:
        with tempfile.TemporaryDirectory(prefix="mdma-rtl-") as directory:
            build = Path(directory)
            prepare(build)
            bench = compile_bench(build, "mdma_tb")
            benchmark_dispatch(build, bench)
            benchmark_alu(build, bench)
        return 0
    pattern = sys.argv[1] if len(sys.argv) > 1 else ""
    fixtures = [path for path in FIXTURE_PATHS if pattern in path.relative_to(FIXTURE_ROOT).as_posix()]
    if not fixtures:
        raise SystemExit(f"no fixtures match {pattern!r}")
    failures = 0
    with tempfile.TemporaryDirectory(prefix="mdma-rtl-") as directory:
        build = Path(directory)
        prepare(build)
        bench = compile_bench(build, "mdma_tb")
        measured = defaultdict(set)
        for path in fixtures:
            name = path.relative_to(FIXTURE_ROOT).as_posix()
            try:
                ticks, clocks, latencies = compare(path, build, bench)
            except (ValueError, subprocess.CalledProcessError) as error:
                print(f"FAIL {name}: {error}", file=sys.stderr)
                if isinstance(error, subprocess.CalledProcessError):
                    print(error.stdout, error.stderr, file=sys.stderr)
                failures += 1
            else:
                print(f"PASS {name}: {ticks} ticks, {clocks} clocks")
                for unit, latency in latencies:
                    measured[unit].add(latency)
        if not pattern:
            names = [*map(str, INSTANCES), "", "MEM store", "MEM load", "MEM swap"]
            for unit, values in sorted(measured.items()):
                low, high = min(values), max(values)
                span = str(low) if low == high else f"{low}–{high}"
                clock = "FU" if 7 <= unit <= 10 else "CPU"
                print(f"ECP5 latency {names[unit]}: {span} {clock} clocks")
            frontend_tests(build)
            board_tests(build)
    print(f"{len(fixtures) - failures}/{len(fixtures)} RTL fixture runs passed")
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())
