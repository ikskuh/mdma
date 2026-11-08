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
  Use a unit name (`MEM`), family name (`ARITH`), or instance name (`ARITH_A`).
  Instance overrides take precedence over family overrides. Repeated overrides
  for the same name use the last value.
- `--trace`: print tick and PC to stderr.
- `--dump-memory FILE`: save final memory after successful halt.

The binary initializes memory starting at byte address zero. PC starts at zero;
words are little-endian. Fetches must be eight-byte aligned and accesses must fit
inside memory. MEM aligns its read and write addresses down to an eight-byte
beat. PACK and UNPACK require natural alignment for the selected type. Store
mask bits of one preserve their byte lanes.

## Execution

`State` contains only flat `sinks` and `sources` arrays, populated with endpoints
at the architecture's indices. `Instruction.execute(state)` knows only endpoint
readiness and read/write operations. Functional units own their queues and output
retirement. Concrete `Unit` subclasses implement `compute()`; shared execution
handles readiness and queues, while `StackUnit` overrides result retirement
for LIFO ordering. Architecture names select subclasses only at initialization.
The external `BinaryStream` owns instruction fetching and CPU endpoints.
`Simulator` owns memory and the execution loop.

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
| MEM | 4 |

For example:

```sh
python src/simulator/simulator.py program.bin --latency MUL=5 --latency MEM=8
```

Python callers can use
`Simulator(image, latencies={"MUL": 5, "MEM": 8, "ARITH_A": 2})`.
Overrides must name known units and contain positive integer tick counts.
Subclasses specify their own `default_latency`; the shared execution loop handles
countdown and output capacity. `State` still contains only endpoint arrays.

MEM queues a load when `READ` is available and queues a store when `WRITE`,
`CHUNK`, and `MASK` are all available. Requests execute in the order they
became ready, including requests queued while MEM was busy. A load and store
that become ready in the same tick share one operation. At completion, MEM
reads the old chunk before applying the store. Instruction fetching is
immediate and independent of MEM latency. STACK uses LIFO output ordering and
STASH uses FIFO ordering.

Values wrap to 64 bits. Signed division truncates toward zero, with a remainder
having the dividend's sign. Division by zero is an error. Shift and rotation
counts use the low six bits. MASK yields all ones and BIT yields zero for N >= 64.
Zero has CLZ=CTZ=64. Invalid types, misalignment, reserved ports, and out-of-range
memory accesses raise errors. Counting down an in-flight operation counts as progress. A tick with no
instruction or unit progress reports a stall; an active infinite loop is stopped by the tick limit.

Run the assembler and simulator tests with `just test` (or
`python -m unittest discover -s tests -v`).

## Assembly behavior tests

Each `.mdma` file in `tests/behavior/` assembles into a complete memory image.
Add one or more postconditions to its leading comment header, for example
`# expect mem64 result = -1`. The runner requires a successful halt and compares
the little-endian 64-bit word at the assembler label `result`. Values follow the
assembler's integer syntax and range. A fixture can declare storage with
`.word` and uses instructions to set up operands, queues, and working memory.
An ordered MEM read followed by consumption of its result can confirm that
earlier stores have completed before halt.

A fault fixture instead declares a single postcondition such as
`# expect fault division_by_zero`. The runner checks the fault code. The
program image and postconditions can also be used by an FPGA runner that
reports the same outcomes.

The runner discovers fixtures recursively. Each fixture has its own test name
derived from its path, so failures identify the fixture and `unittest -k` can
select it.
`00-memory` checks the memory operations used to record results.
`10-instructions` checks CPU instruction behavior.
`20-units` checks individual functional-unit instances using MEM to record results.
`30-interactions` checks behavior that depends on units working together.
`40-faults` checks errors triggered by instructions.
`50-backpressure` checks output stalls using the simulator's separate
eight-entry input and output queues. These fixtures require that buffering on
an FPGA.
Every fixture starts from its own assembled image.

CI requires 100% line and branch coverage of `simulator_core.py` from
the assembly fixtures. The assembler, CLI, and host runner are outside this
measurement.

```sh
python -m unittest discover -s tests -p test_behavior.py -k test_20_units_divs -v
python -m coverage run -m unittest discover -s tests -p test_behavior.py -k BehaviorTest
python -m coverage report --fail-under=100
```
