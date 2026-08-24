import argparse
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path


def main():

    args = parse_args()

    source_text: str
    if args.input == "-":
        source_text = sys.stdin.read()
    else:
        source_text = args.input.read_text("utf-8")

    lines = tuple(parse_asm(source_text))

    for line in lines:
        print(line)


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


def parse_asm(source: str) -> Iterable[AsmLine]:

    for lineno, raw_line in enumerate(source.splitlines(), 1):
        line = raw_line.split("#")[0].strip()
        if not line:
            continue

        label: str | None = None
        ops: list[AsmOp] = []
        immediate: str | None = None
        synchronized = False
        predicate = False

        if ":" in line:
            label, line = line.split(":", maxsplit=1)
            label = label.strip()
            line = line.strip()

        if "[" in line:
            line = line.removesuffix("]")
            line, tail = line.split("[", maxsplit=1)
            tail = tail.strip()
            line = line.strip()
            for _item in tail.split(","):
                item = _item.strip()
                if item.startswith("imm"):
                    if immediate is not None:
                        raise ValueError("duplicate 'imm'")
                    value = item.removeprefix("imm").lstrip().removeprefix("=").lstrip()
                    if not value:
                        raise ValueError(f"empty immediate value in {item!r}")
                    immediate = value
                elif item == "pred":
                    if predicate:
                        raise ValueError("duplicate 'pred'")
                    predicate = True
                elif item == "sync":
                    if synchronized:
                        raise ValueError("duplicate 'sync'")
                    synchronized = True
                else:
                    raise ValueError(f"unknown tag {item!r}")

        for _op in line.split(","):
            op = _op.strip()
            if not op:
                continue

            src_name, dst_name = op.split("->", maxsplit=1)

            ops.append(
                AsmOp(src=src_name.strip(), dst=dst_name.strip()),
            )

        yield AsmLine(
            number=lineno,
            label=label,
            ops=tuple(ops),
            immediate=immediate,
            synchronized=synchronized,
            predicate=predicate,
        )


def parse_args() -> argparse.Namespace:

    parser = argparse.ArgumentParser()

    parser.add_argument("input", type=Path)

    parser.add_argument("-o", "--output", type=Path, required=True)

    return parser.parse_args()


if __name__ == "__main__":
    main()
