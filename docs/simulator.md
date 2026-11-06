# Simulator

The simulator uses Python's standard library. Assemble a program, then run its
binary memory image:

```sh
python src/assembler/mdma_asm.py examples/counter.mdma -o /tmp/counter.bin
python src/simulator/simulator.py /tmp/counter.bin
```

End a code sequence explicitly with:

```text
CONST -> PC [imm=-1]
```

The all-ones 64-bit jump target is the halt marker. It takes effect when all
moves in that instruction finish. Falling off the image is an error, not a halt.
The runner finishes operations already in flight before reporting halt. It does
not start queued operations during this final drain.

Options:

- `--max-ticks N`: execution limit, default 100000.
- `--memory-size N`: memory size in bytes, default the binary's length. Additional
  bytes are zero-filled; a size smaller than the image is rejected.
- `--latency UNIT=TICKS`: override a unit's latency; repeat for multiple units.
  Use a family name (`ARITH`), instance (`ARITH_A`), or `MEM` for LOAD and STORE.
  Instance overrides take precedence over family overrides; LOAD/STORE override
  MEM. Repeated overrides for the same name use the last value.
- `--trace`: print tick and PC to stderr.
- `--dump-memory FILE`: save final memory after successful halt.

The binary initializes memory starting at byte address zero. PC starts at zero;
words are little-endian. Fetches must be eight-byte aligned and accesses must fit
inside memory. LOAD/STORE align their addresses down to an eight-byte beat;
PACK/EXTRACT require natural alignment for the selected width. Store mask bits
of one preserve their byte lanes.

## Execution

`State` contains only flat `sinks` and `sources` arrays, populated with endpoints
at the architecture's indices. `Instruction.execute(state)` knows only endpoint
readiness and read/write operations. Functional units own their queues and output
retirement. Concrete `Unit` subclasses implement `compute()`; shared execution
handles readiness and queues, while `StackUnit` overrides result retirement
for LIFO ordering. Architecture names select subclasses only at initialization.
The external `BinaryStream` owns instruction fetching and CPU
endpoints; `Simulator` owns memory and the execution loop. The architecture
metadata in `mdma.py` remains unchanged.

Each tick:

1. Fetch an instruction if none is active, including its extended immediate.
2. Execute ready moves of the active instruction.
3. Advance each busy functional unit, or start an operation if its inputs and
   output space are ready.
4. If the instruction finished, apply its jump or advance to the next instruction.

At most one instruction is executed per tick. Instruction writes can feed units
that tick; completed unit outputs are available to instructions on the next tick. An
asynchronous instruction retains its unfinished moves across ticks. A synchronized
instruction waits until all its moves can commit together. Predication consumes
one COND token once, skipping all moves if it is zero.

Reading a source stages its value for all subsequent uses in the instruction.
A unit retires all sibling outputs of the same generation together, staging them
for that instruction as well. This allows both ADD and SUB to be read together
without leaving unused results behind. Reading a real source into DISCARD still
consumes it.

## Unit latency

All FIFOs have capacity eight. Each unit has one operation in flight at a time.
It consumes its inputs when starting, counts down once per unit phase, and
computes and publishes its results at completion. Starting counts as the first
phase: latency 1 preserves the original behavior. A unit starts its next operation
no earlier than the tick after completion. Other units continue independently.

Default latencies (ticks):

| Units | Latency |
| --- | ---: |
| ARITH and all other units not listed | 1 |
| MUL, MULS | 2 |
| DIV, DIVS | 7 |
| LOAD, STORE (`MEM`) | 4 |

For example:

```sh
python src/simulator/simulator.py program.bin --latency MUL=5 --latency MEM=8
```

Python callers can use
`Simulator(image, latencies={"MUL": 5, "MEM": 8, "ARITH_A": 2})`.
Overrides must name known units and contain positive integer tick counts.
Subclasses specify their own `default_latency`; the shared execution loop handles
countdown and output capacity. `State` still contains only endpoint arrays.

LOAD reads memory at completion; STORE changes memory at completion. Instruction
fetching is immediate and is not affected by MEM latency. This is a simple
non-pipelined model with no shared memory-bus contention. STACK uses LIFO output
ordering; STASH uses FIFO ordering.

Values wrap to 64 bits. Signed division truncates toward zero, with a remainder
having the dividend's sign. Division by zero is an error. Shift and rotation
counts use the low six bits. MASK yields all ones and BIT yields zero for N >= 64.
Zero has CLZ=CTZ=64. Invalid sizes, misalignment, reserved sinks, and out-of-range
memory accesses raise errors. Counting down an in-flight operation counts as progress. A tick with no
instruction or unit progress reports a stall; an active infinite loop is stopped by the tick limit.

Run the assembler and simulator tests with `just test` (or
`python -m unittest discover -s tests -v`).
