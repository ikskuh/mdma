# Assembler Syntax

Run from the repository root (Python 3.10+; no dependencies):

```sh
python src/assembler/mdma_asm.py examples/counter.mdma -o counter.bin
# Use - as the input filename to read stdin.
```

The output is raw little-endian 64-bit words, starting at byte address zero.
Labels are case-sensitive absolute **byte addresses**, usable in immediates and
`.word` data, including forward references. Labels occupy no space.

```text
start:
    ZERO -> STASH_A
    CONST -> ARITH_A.RHS, STASH_A.OUT -> ARITH_A.LHS [sync]
    ARITH_A.ADD -> STASH_A, CMP.LT -> COND
    CONST -> PC [pred, imm=start]
data: .word 1, -2, 0xff, start
```

Each instruction is one line with up to five comma-separated `SOURCE -> SINK`
moves. Names come from the FIFO tables in `docs/functional-units.md`.
Units with a single source or sink also accept their bare name (`STASH_A`,
`MEM` as a source, etc.). CPU FIFOs accept bare names (`ZERO`, `CONST`, `PC`, etc.)
as well as qualified names such as `CPU.ZERO`. These shorthands are resolved
by the assembler; the architecture tables contain only qualified names.
Moves are sorted by sink for encoding; repeated sinks are
rejected except `DISCARD`. Unused slots encode `ZERO -> DISCARD`.

Optional trailing tags share one bracket block: `[pred, sync, imm=value]`.
`CONST` defaults to 1. Numeric immediates use unsigned or signed 12-bit encoding
when possible with at most four moves. Other values (and five-move instructions)
use an extra 64-bit word. Label immediates always use an extra word, so layout
needs no iterative optimization.

`.word value, ...` emits data words. Values are decimal, `0x` hexadecimal,
`0b` binary, `0o` octal, or a label with an optional byte offset such as
`buffer+4`. Integers must fit signed or unsigned 64 bits;
negative values are emitted in two's complement. `#` starts a comment.
Labels may appear alone or before an instruction or `.word` directive and use
letters, digits, and underscores, starting with a letter or underscore.

`.align N` inserts zero bytes up to the next `N`-byte boundary. `N` must
be a power of two of at least eight. Put the aligned label on the next line.
