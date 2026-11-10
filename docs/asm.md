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
truncate_word:
    STASH_A.OUT -> UNPACK.CHUNK
  , ZERO        -> UNPACK.ADDR
  , CONST       -> UNPACK.TYPE [imm=4]

    UNPACK.VALUE -> STASH_A.IN
  , STACK_B.TOP  -> PC
```

The official assembly style puts one `SOURCE -> SINK` pair on each line.
Start each continuation with a leading comma, and align the `->` arrows
within the instruction. Put instruction tags after the last move. Each
instruction can contain up to five moves. Single-line packs with
comma-separated moves are also accepted. Names come from the FIFO tables
in `docs/functional-units.md`.
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

The command prints code efficiency to stderr after a successful assembly.
It reports unused slots out of five slots per encoded instruction word.
Short immediates occupy one slot, extended immediate words occupy all five,
and `ZERO -> DISCARD` counts as unused. Data words and alignment padding
are excluded.

`.word value, ...` emits data words. Values are decimal, `0x` hexadecimal,
`0b` binary, `0o` octal, or a label with an optional byte offset such as
`buffer+4`. Integers must fit signed or unsigned 64 bits;
negative values are emitted in two's complement. `#` starts a comment.
Labels may appear alone or before an instruction or `.word` directive and use
letters, digits, and underscores, starting with a letter or underscore.

`.align N` inserts zero bytes up to the next `N`-byte boundary. `N` must
be a power of two of at least eight. Put the aligned label on the next line.
