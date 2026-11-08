from abc import ABC, abstractmethod
from dataclasses import dataclass

__all__ = (
    "SINK_BY_INDEX",
    "SINK_BY_NAME",
    "SOURCE_BY_INDEX",
    "SOURCE_BY_NAME",
    "SinkInfo",
    "SourceInfo",
)


@dataclass(frozen=True, kw_only=True, slots=True)
class FunctionUnit:
    name: str

    sinks: tuple["str", ...]
    sources: tuple["str", ...]

    def singleton(self) -> "FunctionUnitInstance":
        return FunctionUnitInstance(unit=self, instance=None)

    def new_instance(self, tag: str) -> "FunctionUnitInstance":
        return FunctionUnitInstance(unit=self, instance=tag)


@dataclass(frozen=True, kw_only=True, slots=True)
class FunctionUnitInstance:
    unit: FunctionUnit
    instance: str | None

    def __str__(self) -> str:
        return f"{self.unit.name}_{self.instance}" if self.instance is not None else self.unit.name


@dataclass(frozen=True, kw_only=True, slots=True)
class FifoInfoBase(ABC):
    index: int  # encoded fifo index
    unit: FunctionUnitInstance  # function unit
    name: str  # full fifo name

    @property
    def full_name(self) -> str:
        return f"{self.unit}.{self.name}"

    @abstractmethod
    def is_sole_fifo(self) -> bool: ...


@dataclass(frozen=True, kw_only=True, slots=True)
class SinkInfo(FifoInfoBase):
    def __post_init__(self):
        assert self.name in self.unit.unit.sinks

    def is_sole_fifo(self) -> bool:
        return len(self.unit.unit.sinks) == 1


@dataclass(frozen=True, kw_only=True, slots=True)
class SourceInfo(FifoInfoBase):
    def __post_init__(self):
        assert self.name in self.unit.unit.sources

    def is_sole_fifo(self) -> bool:
        return len(self.unit.unit.sources) == 1


__CPU = FunctionUnit(
    name="CPU",
    sinks=("PC", "*Reserved[26]*", *(f"*Reserved[{index}]*" for index in range(52, 62)), "COND", "DISCARD"),
    sources=("ZERO", "CONST", "PC_NEXT", *(f"*Reserved[{index}]*" for index in range(59, 61))),
).singleton()

__ARITH = FunctionUnit(name="ARITH", sinks=("LHS", "RHS"), sources=("ADD", "SUB"))
__LOGIC = FunctionUnit(name="LOGIC", sinks=("LHS", "RHS"), sources=("AND", "OR", "XOR"))

__SHIFT = FunctionUnit(name="SHIFT", sinks=("VAL", "CNT"), sources=("LSL", "LSR", "ASR", "ROL", "ROR"))
__UOP = FunctionUnit(name="UOP", sinks=("IN",), sources=("NEG", "NOT", "BSW"))
__SEL = FunctionUnit(name="SEL", sinks=("COND", "TRUE", "FALSE"), sources=("OUT",))
__STASH = FunctionUnit(name="STASH", sinks=("IN",), sources=("OUT",))
__STACK = FunctionUnit(name="STACK", sinks=("PUSH",), sources=("TOP",))

ARITH_A = __ARITH.new_instance("A")
ARITH_B = __ARITH.new_instance("B")
LOGIC_A = __LOGIC.new_instance("A")
LOGIC_B = __LOGIC.new_instance("B")
SHIFT_A = __SHIFT.new_instance("A")
SHIFT_B = __SHIFT.new_instance("B")
CMP = FunctionUnit(name="CMP", sinks=("LHS", "RHS"), sources=("EQ", "NE", "LT", "LTS", "LTE", "LTES")).singleton()
MUL = FunctionUnit(name="MUL", sinks=("LHS", "RHS"), sources=("LO", "HI")).singleton()
MULS = FunctionUnit(name="MULS", sinks=("LHS", "RHS"), sources=("LO", "HI")).singleton()
DIV = FunctionUnit(name="DIV", sinks=("LHS", "RHS"), sources=("QUO", "REM")).singleton()
DIVS = FunctionUnit(name="DIVS", sinks=("LHS", "RHS"), sources=("QUO", "REM")).singleton()
MASK = FunctionUnit(name="MASK", sinks=("N",), sources=("MASK", "BIT")).singleton()
UOP_A = __UOP.new_instance("A")
UOP_B = __UOP.new_instance("B")
BITCNT = FunctionUnit(name="BITCNT", sinks=("IN",), sources=("POP", "CLZ", "CTZ")).singleton()
SEL_A = __SEL.new_instance("A")
SEL_B = __SEL.new_instance("B")
MEM = FunctionUnit(name="MEM", sinks=("READ", "WRITE", "CHUNK", "MASK"), sources=("CHUNK",)).singleton()
PACK = FunctionUnit(name="PACK", sinks=("ADDR", "TYPE", "VALUE"), sources=("ADDR", "CHUNK", "MASK")).singleton()
UNPACK = FunctionUnit(name="UNPACK", sinks=("ADDR", "TYPE", "CHUNK"), sources=("VALUE",)).singleton()
SWIZZLE8 = FunctionUnit(name="SWIZZLE8", sinks=("VALUE", "PATTERN"), sources=("VALUE",)).singleton()
STASH_A = __STASH.new_instance("A")
STASH_B = __STASH.new_instance("B")
STASH_C = __STASH.new_instance("C")
STASH_D = __STASH.new_instance("D")
STACK_A = __STACK.new_instance("A")
STACK_B = __STACK.new_instance("B")

__sinks = (
    SinkInfo(index=0, unit=__CPU, name="PC"),
    SinkInfo(index=1, unit=ARITH_A, name="LHS"),
    SinkInfo(index=2, unit=ARITH_A, name="RHS"),
    SinkInfo(index=3, unit=ARITH_B, name="LHS"),
    SinkInfo(index=4, unit=ARITH_B, name="RHS"),
    SinkInfo(index=5, unit=LOGIC_A, name="LHS"),
    SinkInfo(index=6, unit=LOGIC_A, name="RHS"),
    SinkInfo(index=7, unit=LOGIC_B, name="LHS"),
    SinkInfo(index=8, unit=LOGIC_B, name="RHS"),
    SinkInfo(index=9, unit=SHIFT_A, name="VAL"),
    SinkInfo(index=10, unit=SHIFT_A, name="CNT"),
    SinkInfo(index=11, unit=SHIFT_B, name="VAL"),
    SinkInfo(index=12, unit=SHIFT_B, name="CNT"),
    SinkInfo(index=13, unit=CMP, name="LHS"),
    SinkInfo(index=14, unit=CMP, name="RHS"),
    SinkInfo(index=15, unit=MUL, name="LHS"),
    SinkInfo(index=16, unit=MUL, name="RHS"),
    SinkInfo(index=17, unit=MULS, name="LHS"),
    SinkInfo(index=18, unit=MULS, name="RHS"),
    SinkInfo(index=19, unit=DIV, name="LHS"),
    SinkInfo(index=20, unit=DIV, name="RHS"),
    SinkInfo(index=21, unit=DIVS, name="LHS"),
    SinkInfo(index=22, unit=DIVS, name="RHS"),
    SinkInfo(index=23, unit=MASK, name="N"),
    SinkInfo(index=24, unit=UOP_A, name="IN"),
    SinkInfo(index=25, unit=UOP_B, name="IN"),
    SinkInfo(index=26, unit=__CPU, name="*Reserved[26]*"),
    SinkInfo(index=27, unit=BITCNT, name="IN"),
    SinkInfo(index=28, unit=SEL_A, name="COND"),
    SinkInfo(index=29, unit=SEL_A, name="TRUE"),
    SinkInfo(index=30, unit=SEL_A, name="FALSE"),
    SinkInfo(index=31, unit=SEL_B, name="COND"),
    SinkInfo(index=32, unit=SEL_B, name="TRUE"),
    SinkInfo(index=33, unit=SEL_B, name="FALSE"),
    SinkInfo(index=34, unit=MEM, name="READ"),
    SinkInfo(index=35, unit=MEM, name="WRITE"),
    SinkInfo(index=36, unit=MEM, name="CHUNK"),
    SinkInfo(index=37, unit=MEM, name="MASK"),
    SinkInfo(index=38, unit=PACK, name="ADDR"),
    SinkInfo(index=39, unit=PACK, name="TYPE"),
    SinkInfo(index=40, unit=PACK, name="VALUE"),
    SinkInfo(index=41, unit=UNPACK, name="ADDR"),
    SinkInfo(index=42, unit=UNPACK, name="TYPE"),
    SinkInfo(index=43, unit=UNPACK, name="CHUNK"),
    SinkInfo(index=44, unit=SWIZZLE8, name="VALUE"),
    SinkInfo(index=45, unit=SWIZZLE8, name="PATTERN"),
    SinkInfo(index=46, unit=STASH_A, name="IN"),
    SinkInfo(index=47, unit=STASH_B, name="IN"),
    SinkInfo(index=48, unit=STASH_C, name="IN"),
    SinkInfo(index=49, unit=STASH_D, name="IN"),
    SinkInfo(index=50, unit=STACK_A, name="PUSH"),
    SinkInfo(index=51, unit=STACK_B, name="PUSH"),
    SinkInfo(index=52, unit=__CPU, name="*Reserved[52]*"),
    SinkInfo(index=53, unit=__CPU, name="*Reserved[53]*"),
    SinkInfo(index=54, unit=__CPU, name="*Reserved[54]*"),
    SinkInfo(index=55, unit=__CPU, name="*Reserved[55]*"),
    SinkInfo(index=56, unit=__CPU, name="*Reserved[56]*"),
    SinkInfo(index=57, unit=__CPU, name="*Reserved[57]*"),
    SinkInfo(index=58, unit=__CPU, name="*Reserved[58]*"),
    SinkInfo(index=59, unit=__CPU, name="*Reserved[59]*"),
    SinkInfo(index=60, unit=__CPU, name="*Reserved[60]*"),
    SinkInfo(index=61, unit=__CPU, name="*Reserved[61]*"),
    SinkInfo(index=62, unit=__CPU, name="COND"),
    SinkInfo(index=63, unit=__CPU, name="DISCARD"),
)

__sources = (
    SourceInfo(index=0, unit=__CPU, name="ZERO"),
    SourceInfo(index=1, unit=__CPU, name="CONST"),
    SourceInfo(index=2, unit=__CPU, name="PC_NEXT"),
    SourceInfo(index=3, unit=ARITH_A, name="ADD"),
    SourceInfo(index=4, unit=ARITH_A, name="SUB"),
    SourceInfo(index=5, unit=ARITH_B, name="ADD"),
    SourceInfo(index=6, unit=ARITH_B, name="SUB"),
    SourceInfo(index=7, unit=LOGIC_A, name="AND"),
    SourceInfo(index=8, unit=LOGIC_A, name="OR"),
    SourceInfo(index=9, unit=LOGIC_A, name="XOR"),
    SourceInfo(index=10, unit=LOGIC_B, name="AND"),
    SourceInfo(index=11, unit=LOGIC_B, name="OR"),
    SourceInfo(index=12, unit=LOGIC_B, name="XOR"),
    SourceInfo(index=13, unit=SHIFT_A, name="LSL"),
    SourceInfo(index=14, unit=SHIFT_A, name="LSR"),
    SourceInfo(index=15, unit=SHIFT_A, name="ASR"),
    SourceInfo(index=16, unit=SHIFT_A, name="ROL"),
    SourceInfo(index=17, unit=SHIFT_A, name="ROR"),
    SourceInfo(index=18, unit=SHIFT_B, name="LSL"),
    SourceInfo(index=19, unit=SHIFT_B, name="LSR"),
    SourceInfo(index=20, unit=SHIFT_B, name="ASR"),
    SourceInfo(index=21, unit=SHIFT_B, name="ROL"),
    SourceInfo(index=22, unit=SHIFT_B, name="ROR"),
    SourceInfo(index=23, unit=CMP, name="EQ"),
    SourceInfo(index=24, unit=CMP, name="LT"),
    SourceInfo(index=25, unit=CMP, name="LTS"),
    SourceInfo(index=26, unit=CMP, name="LTE"),
    SourceInfo(index=27, unit=CMP, name="LTES"),
    SourceInfo(index=28, unit=MUL, name="LO"),
    SourceInfo(index=29, unit=MUL, name="HI"),
    SourceInfo(index=30, unit=MULS, name="LO"),
    SourceInfo(index=31, unit=MULS, name="HI"),
    SourceInfo(index=32, unit=DIV, name="REM"),
    SourceInfo(index=33, unit=DIV, name="QUO"),
    SourceInfo(index=34, unit=DIVS, name="REM"),
    SourceInfo(index=35, unit=DIVS, name="QUO"),
    SourceInfo(index=36, unit=SEL_A, name="OUT"),
    SourceInfo(index=37, unit=SEL_B, name="OUT"),
    SourceInfo(index=38, unit=MEM, name="CHUNK"),
    SourceInfo(index=39, unit=PACK, name="CHUNK"),
    SourceInfo(index=40, unit=PACK, name="MASK"),
    SourceInfo(index=41, unit=UNPACK, name="VALUE"),
    SourceInfo(index=42, unit=SWIZZLE8, name="VALUE"),
    SourceInfo(index=43, unit=STASH_A, name="OUT"),
    SourceInfo(index=44, unit=STASH_B, name="OUT"),
    SourceInfo(index=45, unit=STASH_C, name="OUT"),
    SourceInfo(index=46, unit=STASH_D, name="OUT"),
    SourceInfo(index=47, unit=STACK_A, name="TOP"),
    SourceInfo(index=48, unit=STACK_B, name="TOP"),
    SourceInfo(index=49, unit=MASK, name="MASK"),
    SourceInfo(index=50, unit=MASK, name="BIT"),
    SourceInfo(index=51, unit=UOP_A, name="NEG"),
    SourceInfo(index=52, unit=UOP_A, name="NOT"),
    SourceInfo(index=53, unit=UOP_A, name="BSW"),
    SourceInfo(index=54, unit=UOP_B, name="NEG"),
    SourceInfo(index=55, unit=UOP_B, name="NOT"),
    SourceInfo(index=56, unit=UOP_B, name="BSW"),
    SourceInfo(index=57, unit=PACK, name="ADDR"),
    SourceInfo(index=58, unit=CMP, name="NE"),
    SourceInfo(index=59, unit=__CPU, name="*Reserved[59]*"),
    SourceInfo(index=60, unit=__CPU, name="*Reserved[60]*"),
    SourceInfo(index=61, unit=BITCNT, name="POP"),
    SourceInfo(index=62, unit=BITCNT, name="CLZ"),
    SourceInfo(index=63, unit=BITCNT, name="CTZ"),
)

SINK_BY_NAME: dict[str, SinkInfo] = {sink.full_name: sink for sink in __sinks}
SINK_BY_INDEX: dict[int, SinkInfo] = {sink.index: sink for sink in __sinks}

SOURCE_BY_NAME: dict[str, SourceInfo] = {source.full_name: source for source in __sources}
SOURCE_BY_INDEX: dict[int, SourceInfo] = {source.index: source for source in __sources}
