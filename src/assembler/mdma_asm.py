"""Minimal two-pass MDMA assembler; see docs/asm.md for syntax."""

import argparse
import re
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

# Allow running this file directly without installing the project.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pylibs"))
from mdma import SINK_BY_NAME, SOURCE_BY_NAME


def assembler_names(table):
    names = dict(table)
    for fifo in table.values():
        if fifo.unit.unit.name == "CPU":
            names[fifo.name] = fifo
        elif fifo.is_sole_fifo():
            names[str(fifo.unit)] = fifo
    return names


SOURCES = assembler_names(SOURCE_BY_NAME)
SINKS = assembler_names(SINK_BY_NAME)


@dataclass(frozen=True, slots=True, kw_only=True)
class AsmOp:
    src: str
    dst: str


@dataclass(frozen=True, slots=True, kw_only=True)
class AsmLine:
    number: int
    label: str | None
    ops: tuple[AsmOp, ...]
    immediate: str | None
    synchronized: bool
    predicate: bool
    words: tuple[str, ...] = ()
    alignment: int = 0


def parse_asm(source: str) -> Iterable[AsmLine]:
    for number, raw in enumerate(source.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            label = None
            if ":" in line:
                label, line = (part.strip() for part in line.split(":", 1))
                if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", label):
                    raise ValueError(f"invalid label {label!r}")
            ops = []
            words = ()
            immediate = None
            tags = set()
            alignment = 0
            if line.split(maxsplit=1)[:1] == [".align"]:
                if label is not None:
                    raise ValueError("put the label after .align on its own line")
                try:
                    alignment = integer(line[6:].strip())
                except ValueError:
                    raise ValueError("expected .align followed by a byte alignment") from None
                if alignment < 8 or alignment > sys.maxsize or alignment & (alignment - 1):
                    raise ValueError("alignment must be a power of two of at least eight bytes")
            elif line.startswith(".word"):
                if not line.startswith(".word ") and not line.startswith(".word\t"):
                    raise ValueError("expected .word followed by values")
                words = tuple(value.strip() for value in line[5:].split(","))
                if not all(words):
                    raise ValueError("empty .word value")
            elif line:
                if "[" in line:
                    if not line.endswith("]") or line.count("[") != 1:
                        raise ValueError("expected one trailing [tag, ...] block")
                    line, tail = line[:-1].split("[", 1)
                    for tag in tail.split(","):
                        tag = tag.strip()
                        match = re.fullmatch(r"imm\s*=\s*(.+)", tag)
                        name = "imm" if match else tag
                        if not match and name not in {"pred", "sync"}:
                            raise ValueError(f"unknown tag {tag!r}")
                        if name in tags:
                            raise ValueError(f"duplicate {name!r}")
                        tags.add(name)
                        if match:
                            immediate = match[1].strip()
                if "]" in line:
                    raise ValueError("unexpected ']'")
                for op in line.split(","):
                    parts = op.strip().split("->")
                    if len(parts) != 2 or not all(part.strip() for part in parts):
                        raise ValueError(f"invalid move {op.strip()!r}")
                    ops.append(AsmOp(src=parts[0].strip(), dst=parts[1].strip()))
            yield AsmLine(number=number, label=label, ops=tuple(ops), immediate=immediate,
                          synchronized="sync" in tags, predicate="pred" in tags, words=words,
                          alignment=alignment)
        except ValueError as exc:
            raise ValueError(f"line {number}: {exc}") from exc


def integer(value: str) -> int:
    return int(value, 10) if re.fullmatch(r"[+-]?[0-9]+", value) else int(value, 0)


def immediate_mode(line: AsmLine) -> int:
    if line.immediate is None:
        return 0
    try:
        value = integer(line.immediate)
    except ValueError:
        # ponytail: label references always use an extra word; avoids iterative layout.
        return 1
    if value == 1:
        return 0
    if len(line.ops) <= 4:
        if 0 <= value <= 4095:
            return 2
        if -2048 <= value < 0:
            return 3
    return 1


def resolve(value: str, labels: dict[str, int]) -> int:
    if value in labels:
        result = labels[value]
    else:
        try:
            result = integer(value)
        except ValueError:
            raise ValueError(f"unknown label or invalid integer {value!r}") from None
    if not -(1 << 63) <= result < (1 << 64):
        raise ValueError(f"value out of 64-bit range: {value}")
    return result & ((1 << 64) - 1)


def resolve_word(value: str, labels: dict[str, int]) -> int:
    offset = re.fullmatch(r"([A-Za-z_][A-Za-z_0-9]*)\s*([+-])\s*(\w+)", value)
    if offset and offset[1] in labels:
        displacement = integer(offset[3])
        if offset[2] == "-":
            displacement = -displacement
        return resolve(str(labels[offset[1]] + displacement), labels)
    return resolve(value, labels)


def assemble(source: str) -> bytes:
    image, _ = assemble_with_labels(source)
    return image


def assemble_with_labels(source: str) -> tuple[bytes, dict[str, int]]:
    """Assemble a binary and return its absolute byte addresses by label."""
    lines = tuple(parse_asm(source))
    labels = {}
    address = 0
    for line in lines:
        if line.alignment:
            address += -address % line.alignment
        if line.label is not None:
            if line.label in labels:
                raise ValueError(f"line {line.number}: duplicate label {line.label!r}")
            labels[line.label] = address
        address += 8 * (len(line.words) if line.words else
                        1 + (immediate_mode(line) == 1) if line.ops else 0)

    output = bytearray()
    for line in lines:
        try:
            if line.alignment:
                output.extend(bytes(-len(output) % line.alignment))
                continue
            if line.words:
                words = [resolve_word(value, labels) for value in line.words]
            elif line.ops:
                mode = immediate_mode(line)
                slots = 4 if mode in (2, 3) else 5
                if len(line.ops) > slots:
                    raise ValueError(f"at most {slots} moves allowed")
                moves = []
                for op in line.ops:
                    if op.src not in SOURCES:
                        raise ValueError(f"unknown source {op.src!r}")
                    if op.dst not in SINKS:
                        raise ValueError(f"unknown sink {op.dst!r}")
                    moves.append((SINKS[op.dst].index, SOURCES[op.src].index))
                moves.sort(key=lambda move: move[0])
                sinks = [dst for dst, _ in moves if dst != 63]
                if len(sinks) != len(set(sinks)):
                    raise ValueError("duplicate sink in instruction")
                moves.extend([(63, 0)] * (slots - len(moves)))
                word = (int(line.predicate) << 63) | (int(line.synchronized) << 62) | (mode << 60)
                previous = -1
                for slot, (dst, src) in enumerate(moves):
                    offset = max(0, dst - previous - 1)
                    word |= (src | (offset << 6)) << (12 * slot)
                    previous = dst
                value = resolve(line.immediate, labels) if line.immediate is not None else 1
                if mode in (2, 3):
                    word |= (value & 4095) << 48
                words = [word, value] if mode == 1 else [word]
            else:
                continue
            for word in words:
                output.extend(word.to_bytes(8, "little"))
        except ValueError as exc:
            raise ValueError(f"line {line.number}: {exc}") from exc
    return bytes(output), labels


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="assembly file, or - for stdin")
    parser.add_argument("-o", "--output", type=Path, required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    try:
        source = sys.stdin.read() if args.input == "-" else Path(args.input).read_text("utf-8")
        binary = assemble(source)
        args.output.write_bytes(binary)
    except (ValueError, OSError) as exc:
        print(f"mdma_asm: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
