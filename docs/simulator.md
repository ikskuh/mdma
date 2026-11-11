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
The runner drains complete operand bundles before reporting halt, including
MEM requests in issue order. Unread results do not block the drain, and
faults from drained operations still surface.

Options:

- `--max-ticks N`: execution limit, default 100000.
- `--memory-size N`: memory size in bytes, default the binary's length. Additional
  bytes are zero-filled; a size smaller than the image is rejected.
- `--profile FILE` loads the same timing file as `qbe-mdma --schedule FILE`.
- `--latency UNIT=TICKS` overrides the latency of a unit or family. Instance
  overrides such as `ARITH_A` and `MEM_READ` take precedence over family
  overrides such as `ARITH` and `MEM`. The last override for a name wins.
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

Operand and result FIFOs have capacity eight. Each STACK has sixteen places
shared by accepted pushes and resident values. Later TOP reads wait for
pending pushes, preserving LIFO order for every configured latency. Reads
on an edge precede that edge's sink writes, including simultaneous stack
exchanges. A unit takes its inputs when it starts an
operation. Starting counts as the first tick of latency, and instructions
can read the result on the tick after completion. The issue interval sets
the minimum spacing between starts. An interval shorter than the latency
allows multiple operations in flight, with results published in issue order.

Default latencies (ticks):

| Units | Latency |
| --- | ---: |
| ARITH and all other units not listed | 1 |
| MUL, MULS | 2 |
| DIV, DIVS | 7 |
| MEM | 4 |

With the built-in timings, the issue interval equals the latency. A timing
profile provides both values per unit, including separate `MEM_READ` and
`MEM_WRITE` rows. Stack ordering is always required. Legacy
`stack_push_ordered yes` entries are accepted; `no` is rejected.
When combined with a profile, `--latency` changes only the latency column.

```sh
python src/simulator/simulator.py program.bin --profile src/qbe/profiles/ecp5.conf
```

Python callers can pass the same path as `Simulator(image, profile=path)` and
optionally pass `latencies={"MUL": 5, "ARITH_A": 2}`. The legacy ECP5
profile models FU timing. The Python runner fetches instructions immediately.
See the [legacy ECP5 statistics](ecp5-legacy-stats.md) for RTL measurements.

MEM queues a load when `READ` is available and queues a store when `WRITE`,
`CHUNK`, and `MASK` are all available. Requests execute in the order they
became ready, including requests queued while MEM was busy. A load and store
that become ready in the same tick share one operation, using the longer
latency and issue interval of the two rows. At completion, MEM reads the old
chunk before applying the store. Instruction fetching is
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
earlier stores have completed while the program is running.

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
