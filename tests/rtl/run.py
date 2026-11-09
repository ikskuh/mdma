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
from simulator import Simulator, SimulationError
from simulator_core import INSTANCES
from rtl_runner import compile_bench, execute_image, prepare, write_image

def benchmark_dispatch(build):
    source = Path(__file__).with_name("five_wide.mdma").read_text()
    image, labels = assemble_with_labels(source)
    path = build / "five_wide.hex"
    write_image(image, path)
    bench = compile_bench(build, "mdma_tb")
    result = subprocess.run(["vvp", str(bench), "+five_wide", f"+image={path}",
                             f"+words={len(image) // 8}", f"+dump={build / 'five_wide.dump'}",
                             f"+first_pc={labels['first_dispatch']}", f"+second_pc={labels['second_dispatch']}"],
                            check=True, capture_output=True, text=True, timeout=15)
    print("\n".join(line for line in result.stdout.splitlines() if line.startswith("BENCH ")))


def serial_test(build):
    image, labels = assemble_with_labels((ROOT / "examples/serial-echo.mdma").read_text())
    hex_path = build / "serial.hex"
    write_image(image, hex_path)
    bench = compile_bench(build, "mdma_serial_tb")
    for mem_half_period in (8, 3):
        subprocess.run(["vvp", str(bench), f"+image={hex_path}", f"+words={len(image) // 8}",
                        f"+cell={labels['cell'] // 8}", f"+readback={labels['readback'] // 8}",
                        f"+mem_half_period={mem_half_period}"], check=True)


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
            benchmark_dispatch(build)
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
            serial_test(build)
    print(f"{len(fixtures) - failures}/{len(fixtures)} RTL fixture runs passed")
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())
