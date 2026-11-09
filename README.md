# Multiple Data Moving Architecture

The MDMA (Multiple Data Moving Architecture) is a transport-triggered dataflow oriented super scalar CPU architecture which can provide high throughput computation.

Unlike typical instruction-based architectures, MDMA only has a single instruction which encodes how and when data flows, and not what operations the CPU should perform in this instruction. Instead, the instruction moves data between different FIFOs (queues), and each queue has a consumer attached which defines the semantics of the move.

Each instruction encodes up to 5 move operations, which allows multiple data values to flow between the different FIFOs.

## Why?

A friend once told me that he just figured out that the `MOV` instruction of many CPUs doesn't actually move data, but copies it. This [nerd sniped](https://xkcd.com/356/) me into designing a CPU which actually *moves* data instead of *copying* it. Thus, MDMA was born.

## Overview

> TODO
>
> Talk about asynchrony, FIFOs, moves, background memory loads, hidden latencies, ...

## Instruction Encoding

Instructions have 64 bit and subdivide them into 4 or 5 move operations as well as 4 configuration bits:

| Bit Range | Name           | Function                                                                                                     |
| --------- | -------------- | ------------------------------------------------------------------------------------------------------------ |
| [63]      | Predication    | If 1, the instruction is predicated.                                                                         |
| [62]      | Synchronized   | If 1, all moves will happen synchronously, otherwise fire as soon as possible.                               |
| [61:60]   | Immediate      | Defines the value of the `CONST` source. See below for the different values.                                 |
| [59:54]   | Sink 4 Offset  | Index offset of the sink FIFO for the fifth operation (*see below*) or upper 6 bits of the immediate value.. |
| [53:48]   | Source 4 Index | Index of the source FIFO for the fifth operation or lower 6 bits of the immediate value.                     |
| [47:42]   | Sink 3 Offset  | Index offset of the sink FIFO for the fourth operation (*see below*).                                        |
| [41:36]   | Source 3 Index | Index of the source FIFO for the fourth operation.                                                           |
| [35:30]   | Sink 2 Offset  | Index offset of the sink FIFO for the third operation (*see below*).                                         |
| [29:24]   | Source 2 Index | Index of the source FIFO for the third operation.                                                            |
| [23:18]   | Sink 1 Offset  | Index offset of the sink FIFO for the second operation (*see below*).                                        |
| [17:12]   | Source 1 Index | Index of the source FIFO for the second operation.                                                           |
| [11:6]    | Sink 0 Offset  | Index of the sink FIFO for the first operation.                                                              |
| [5:0]     | Source 0 Index | Index of the source FIFO for the first operation.                                                            |

This means we have 5 movement pairs, each consisting of a 6 bit source and sink index. The source index is taken verbatim from the instruction encoding, while the sink index is encoded in a way that it's guaranteed to be unique for each instruction, removing ambiguities from the encoding:

- Sink 0 Index is Sink 0 Offset.
- Sink 1 Index is Sink 0 Index + Sink 1 Offset + 1
- Sink 2 Index is Sink 1 Index + Sink 2 Offset + 1
- Sink 3 Index is Sink 2 Index + Sink 3 Offset + 1
- Sink 4 Index is Sink 3 Index + Sink 4 Offset + 1

Each of these additions saturate at 63, we can have each sink lower than 63 only exactly once in the encoding. This removes a fault state from the hardware.

The semantics for what function is behind a source and sink FIFO index is defined through the functional units.

### Immediate Configuration

The *Immediate* field defines what value the `CONST` source will yield for this instruction.

Four different values are possible:

| Value | Name      | Description                                                                                    |
|-------|-----------|------------------------------------------------------------------------------------------------|
| 0     | One       | `CONST` yields `1` (default)                                                                   |
| 1     | Extended  | `CONST` is the value of the next instruction word.                                             |
| 2     | Unsigned  | `{ Sink 4, Source 4 }` form a 12 bit unsigned immediate value instead of a moving pair.        |
| 3     | Signed    | `{ Sink 4, Source 4 }` form a 12 bit sign-extended immediate value instead of a moving pair.   |

- If *Immediate* is *Unsigned* or *Signed*, the CPU will not execute the fourth moving pair (*Sink 4*, *Source 4*), but treat `[59:48]` as a 12 bit value.
    - For both modes, `CONST[11:0]` will be set to `instr[59:48]`.
    - When *Immediate* is *Unsigned*, all bits in `CONST[63:12]` will be set to `0` (zero extension).
    - When *Immediate* is *Signed*, all bits in `CONST[63:12]` will be set to `instr[59]` (sign extension).
- If *Immediate* is *Extended*, the CPU will fetch the instruction word (64 bit), and afterwards another word (64 bit) from the instruction bus, incrementing PC twice.

This allows most instructions to be a single instruction word, but also gives us the ability to have full 64 bit immediates.

## Functional Units

A functional unit implements the actual computation, and has zero or more sinks and sources.

A functional unit consumes values from sources, performs computations on them and pushes its outputs to sinks.

A simple and concrete example is the `ARITH` functional unit, which performs basic arithmetic operations like `ADD` and `SUB`.

`ARITH` has two sinks, `LHS` and `RHS`, and two sources, `SUM` and `DIFF`.

Both the sinks and the sources are FIFOs, and as soon as `ARITH` has a value on `LHS` and `RHS`, it concurrently computes `LHS + RHS` and `LHS - RHS`, and pushes the output values to `SUM` and `DIFF` as soon as they are available.

When a value is consumed from either `SUM` or `DIFF`, both sources drop their value synchronously. This prevents that unused values pile up in FIFOs.

Another very simple functional unit is `STASH`, which is a loopback fifo, where writing a value into its single sink will make it available in the same sequence on its single source. This is kinda like a "register" on a typical CPU in that it can save an intermediate value of a computation.

See [`docs/functional-units.md`](docs/functional-units.md) for a full reference.

### Memory and Typed Values

A single `MEM` functional unit handles loads and stores in issue order. Its inputs are `READ` (load address), `WRITE` (store address), `CHUNK`, and `MASK`; loads produce `MEM.CHUNK`. A load consumes `READ` independently. A store consumes `(WRITE, CHUNK, MASK)` atomically. If read and write trigger together, the read observes memory before the write, allowing a memory cell to be swapped with a supplied value.
Halt drains complete operand bundles, including MEM requests in issue order.
Unread results do not block the drain, and errors still surface.

Typed memory operations use two helper FUs:

- `PACK: (Address, Type, Value) -> (Address, Chunk, Mask)` positions a scalar in a chunk, generates the store mask, and forwards the address unchanged.
- `UNPACK: (Address, Type, Chunk) -> (Value)` extracts a scalar and extends it to 64 bits: sign extension for signed types, zero extension for unsigned types.

`Type` is `enum(u8, i8, u16, i16, u32, i32, u64, i64)`, encoded as values 0–7 in that order. Extension is part of `UNPACK`; there is no separate extension FU.

## Assembler Syntax

The assembler syntax is straightforward and does not require much variety syntax:

```rb
label:
    FU1.SOURCE_A -> FU2.SINK_A                                          # a single move pair, the other four are ZERO -> DISCARD
    FU1.SOURCE_B -> FU2.SINK_B, FU3.SOURCE_C -> FU2.SOURCE_A            # two move pairs
    FU1.SOURCE_B -> FU2.SINK_B, FU3.SOURCE_C -> FU2.SOURCE_A [pred]     # two move pairs, sets *Predication* bit
    FU1.SOURCE_B -> FU2.SINK_B, FU3.SOURCE_C -> FU2.SOURCE_A [imm=1234] # two move pairs, sets *Immediate* bits
    FU1.SOURCE_B -> FU2.SINK_B, FU3.SOURCE_C -> FU2.SOURCE_A [sync]     # two move pairs, sets *Synchronized* bit.
    SIMPLE_FU    -> FU.SINK_A,  FU.SOURCE_A  -> SIMPLE_FU               # functional units with a single sink/source can be used as a name directly
    
.word 1                                                                 # emits a single 64 bit words
.word 1,2,3                                                             # emits 3 64 bit words
```

See [`docs/asm.md`](docs/asm.md) for a full reference.

## Design Decisions

- The system uses 64 bit word size and two 64 bit busses.
    - CPU instructions are fetched through the read-only *instruction bus*.
    - Memory operations access the read-write *data bus*.
- The 64 bit bus can only do full loads, but allows arbitrary byte-lane selection for stores.
- Memory addresses need to be aligned to 8, which allows encoding a byte offset in the lower 3 bits.
- Memory indexing is little endian.
- Store masks are inverted so a natural word store is not consuming an immediate value, but can use the `ZERO` source.

## Simulator

Run assembled binary images with `python src/simulator/simulator.py program.bin`.
End programs with `CONST -> PC [imm=-1]`. See [the simulator reference](docs/simulator.md)
for timing, memory, and CLI options.

The ECP5 Verilog softcore runs the same behavior fixtures.
[FPGA build, interfaces, and timing](docs/fpga.md)

The standalone QBE backend emits MDMA assembly and can validate the CoreMark
kernels in the simulator. [QBE backend and CoreMark validation](docs/qbe.md)
