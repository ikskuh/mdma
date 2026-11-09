"""Run an assembled image against the clocked Verilog model."""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "src/rtl"
BENCHES = ROOT / "tests/rtl"
FAULTS = (
    None, "reserved_sink", "reserved_source", "memory_bounds", "division_by_zero",
    "invalid_type", "misaligned_typed_address", "unaligned_pc", "stall",
)


def write_image(image, path):
    path.write_text("".join(f"{int.from_bytes(image[i:i + 8], 'little'):016x}\n"
                            for i in range(0, len(image), 8)))


def prepare(build):
    with (build / "mdma_ports.vh").open("w") as header:
        subprocess.run([sys.executable, str(RTL / "gen_ports.py")], stdout=header, check=True)


def compile_bench(build, name):
    bench = build / name
    subprocess.run(["iverilog", "-g2012", "-I", str(build), "-s", name, "-o", str(bench),
                    *map(str, sorted(RTL.glob("*.v"))), str(BENCHES / (name + ".v"))], check=True)
    return bench


def execute_image(image, build, bench, *, max_clocks=250000, trace=False):
    if not 1 <= len(image) // 8 <= 16384 or len(image) > 16384 * 8:
        raise ValueError("RTL bench requires an image of 1 to 16384 64-bit words")
    image_path = build / "image.hex"
    dump_path = build / "dump.hex"
    write_image(image, image_path)
    command = ["vvp", str(bench), f"+image={image_path}", f"+dump={dump_path}",
               f"+words={len(image) // 8}", f"+max_clocks={max_clocks}"]
    if trace:
        command.append("+trace")
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError(f"RTL bench failed: {(result.stderr or result.stdout).strip()}")
    match = re.search(r"^RESULT (\d+) (\d+) (\d+)$", result.stdout, re.MULTILINE)
    if match is None:
        raise ValueError(f"missing RTL result: {result.stdout}")
    code, ticks, clocks = map(int, match.groups())
    words = (int(line, 16) for line in dump_path.read_text().splitlines() if line and not line.startswith("//"))
    memory = b"".join(word.to_bytes(8, "little") for word in words)
    memory += image[len(memory):]  # An incomplete final word is outside bus bounds.
    return FAULTS[code], ticks, clocks, memory, result.stdout
