# Function Units Specification

## Overview

### Table of Sinks

| Sink Index | Functional Unit | Instance | Name      | Description                                                 |
| ---------- | --------------- | -------- | --------- | ----------------------------------------------------------- |
| 0          | *CPU*           | -        | `PC`      | If written, will set the next instruction address.          |
| 1          | ARITH           | `A`      | `LHS`     | Arithmetic, left-hand side                                  |
| 2          | ARITH           | `A`      | `RHS`     | Arithmetic, right-hand side                                 |
| 3          | ARITH           | `B`      | `LHS`     | Arithmetic, left-hand side                                  |
| 4          | ARITH           | `B`      | `RHS`     | Arithmetic, right-hand side                                 |
| 5          | LOGIC           | `A`      | `LHS`     | Bitwise Logic, left-hand side                               |
| 6          | LOGIC           | `A`      | `RHS`     | Bitwise Logic, right-hand side                              |
| 7          | LOGIC           | `B`      | `LHS`     | Bitwise Logic, left-hand side                               |
| 8          | LOGIC           | `B`      | `RHS`     | Bitwise Logic, right-hand side                              |
| 9          | SHIFT           | `A`      | `VAL`     | Shifter, Shifted value.                                     |
| 10         | SHIFT           | `A`      | `CNT`     | Shifter, Number of bits to shift.                           |
| 11         | SHIFT           | `B`      | `VAL`     | Shifter, Shifted value.                                     |
| 12         | SHIFT           | `B`      | `CNT`     | Shifter, Number of bits to shift.                           |
| 13         | CMP             |          | `LHS`     | Comparison, left-hand side                                  |
| 14         | CMP             |          | `RHS`     | Comparison, right-hand side                                 |
| 15         | MUL             |          | `LHS`     | Unsigned multiplication, left-hand side                     |
| 16         | MUL             |          | `RHS`     | Unsigned multiplication, right-hand side                    |
| 17         | MULS            |          | `LHS`     | Signed multiplication, left-hand side                       |
| 18         | MULS            |          | `RHS`     | Signed multiplication, right-hand side                      |
| 19         | DIV             |          | `LHS`     |                                                             |
| 20         | DIV             |          | `RHS`     |                                                             |
| 21         | DIVS            |          | `LHS`     |                                                             |
| 22         | DIVS            |          | `RHS`     |                                                             |
| 23         | MASK            |          | `N`       |                                                             |
| 24         | UOP             | `A`      | `IN`      |                                                             |
| 25         | UOP             | `B`      | `IN`      |                                                             |
| 26         | *reserved*      |          |           |                                                             |
| 27         | BITCNT          |          | `IN`      |                                                             |
| 28         | SEL             | `A`      | `COND`    | Selector condition, `0` is false, else true.                |
| 29         | SEL             | `A`      | `TRUE`    | Selector truthy value Used when `COND` is not 0.            |
| 30         | SEL             | `A`      | `FALSE`   | Selector falsy value. Used when `COND` is 0.                |
| 31         | SEL             | `B`      | `COND`    | Selector condition, `0` is false, else true.                |
| 32         | SEL             | `B`      | `TRUE`    | Selector truthy value Used when `COND` is not 0.            |
| 33         | SEL             | `B`      | `FALSE`   | Selector falsy value. Used when `COND` is 0.                |
| 34         | MEM             |          | `READ`    | Load address; produces a full 64-bit chunk.                  |
| 35         | MEM             |          | `WRITE`   | Store address; consumed atomically with CHUNK and MASK.     |
| 36         | MEM             |          | `CHUNK`   | 64-bit chunk to store.                                      |
| 37         | MEM             |          | `MASK`    | Inverted byte-lane mask: 0 writes, 1 preserves.              |
| 38         | PACK            |          | `ADDR`    | Full address; low 3 bits select the starting byte lane.     |
| 39         | PACK            |          | `TYPE`    | Type enum (0–7); selects width and signedness.              |
| 40         | PACK            |          | `VALUE`   | Scalar value to pack.                                      |
| 41         | UNPACK          |          | `ADDR`    | Full address; low 3 bits select the starting byte lane.     |
| 42         | UNPACK          |          | `TYPE`    | Type enum (0–7); selects width and signedness.              |
| 43         | UNPACK          |          | `CHUNK`   | 64-bit chunk to unpack.                                    |
| 44         | SWIZZLE8        |          | `VALUE`   |                                                             |
| 45         | SWIZZLE8        |          | `PATTERN` |                                                             |
| 46         | STASH           | `A`      | `IN`      |                                                             |
| 47         | STASH           | `B`      | `IN`      |                                                             |
| 48         | STASH           | `C`      | `IN`      |                                                             |
| 49         | STASH           | `D`      | `IN`      |                                                             |
| 50         | STACK           | `A`      | `PUSH`    |                                                             |
| 51         | STACK           | `B`      | `PUSH`    |                                                             |
| 52         | *reserved*      |          |           |                                                             |
| 53         | *reserved*      |          |           |                                                             |
| 54         | *reserved*      |          |           |                                                             |
| 55         | *reserved*      |          |           |                                                             |
| 56         | *reserved*      |          |           |                                                             |
| 57         | *reserved*      |          |           |                                                             |
| 58         | *reserved*      |          |           |                                                             |
| 59         | *reserved*      |          |           |                                                             |
| 60         | *reserved*      |          |           |                                                             |
| 61         | *reserved*      |          |           |                                                             |
| 62         | *CPU*           |          | `COND`    | Stashes a predication, non-zero means *execute*.            |
| 63         | *CPU*           | -        | `DISCARD` | Always writable, ignores all written values.                |

### Table of Sources

| Source Index | Functional Unit | Instance | Name      | Description                                   |
| ------------ | --------------- | -------- | --------- | --------------------------------------------- |
| 0            | *CPU*           | -        | `ZERO`    | Always zero.                                  |
| 1            | *CPU*           | -        | `CONST`   | Constant 1, or instruction immediate value.   |
| 2            | *CPU*           | -        | `PC_NEXT` | Address of the next instruction.              |
| 3            | `ARITH`         | `A`      | `ADD`     | Sum of `LHS` and `RHS`.                       |
| 4            | `ARITH`         | `A`      | `SUB`     | Difference between `LHS` and `RHS`.           |
| 5            | `ARITH`         | `B`      | `ADD`     | Sum of `LHS` and `RHS`.                       |
| 6            | `ARITH`         | `B`      | `SUB`     | Difference between `LHS` and `RHS`.           |
| 7            | `LOGIC`         | `A`      | `AND`     | Bitwise AND between `LHS` and `RHS`.          |
| 8            | `LOGIC`         | `A`      | `OR`      | Bitwise inclusive OR between `LHS` and `RHS`. |
| 9            | `LOGIC`         | `A`      | `XOR`     | Bitwise exclusive OR between `LHS` and `RHS`. |
| 10           | `LOGIC`         | `B`      | `AND`     | Bitwise AND between `LHS` and `RHS`.          |
| 11           | `LOGIC`         | `B`      | `OR`      | Bitwise inclusive OR between `LHS` and `RHS`. |
| 12           | `LOGIC`         | `B`      | `XOR`     | Bitwise exclusive OR between `LHS` and `RHS`. |
| 13           | `SHIFT`         | `A`      | `LSL`     |                                               |
| 14           | `SHIFT`         | `A`      | `LSR`     |                                               |
| 15           | `SHIFT`         | `A`      | `ASR`     |                                               |
| 16           | `SHIFT`         | `A`      | `ROL`     |                                               |
| 17           | `SHIFT`         | `A`      | `ROR`     |                                               |
| 18           | `SHIFT`         | `B`      | `LSL`     |                                               |
| 19           | `SHIFT`         | `B`      | `LSR`     |                                               |
| 20           | `SHIFT`         | `B`      | `ASR`     |                                               |
| 21           | `SHIFT`         | `B`      | `ROL`     |                                               |
| 22           | `SHIFT`         | `B`      | `ROR`     |                                               |
| 23           | CMP             | -        | `EQ`      |                                               |
| 24           | CMP             | -        | `LT`      |                                               |
| 25           | CMP             | -        | `LTS`     |                                               |
| 26           | CMP             | -        | `LTE`     |                                               |
| 27           | CMP             | -        | `LTES`    |                                               |
| 28           | MUL             | -        | `LO`      |                                               |
| 29           | MUL             | -        | `HI`      |                                               |
| 30           | MULS            | -        | `LO`      |                                               |
| 31           | MULS            | -        | `HI`      |                                               |
| 32           | DIV             | -        | `REM`     |                                               |
| 33           | DIV             | -        | `QUO`     |                                               |
| 34           | DIVS            | -        | `REM`     |                                               |
| 35           | DIVS            | -        | `QUO`     |                                               |
| 36           | SEL             | `A`      | `OUT`     |                                               |
| 37           | SEL             | `B`      | `OUT`     |                                               |
| 38           | MEM             | -        | `CHUNK`   | Full 64-bit chunk returned by a load.          |
| 39           | PACK            | -        | `CHUNK`   | Scalar positioned in its target byte lanes.   |
| 40           | PACK            | -        | `MASK`    | Inverted byte-lane mask for MEM.MASK.          |
| 41           | UNPACK          | -        | `VALUE`   | Extracted, sign- or zero-extended scalar.     |
| 42           | SWIZZLE8        | -        | `VALUE`   |                                               |
| 43           | STASH           | `A`      | `OUT`     |                                               |
| 44           | STASH           | `B`      | `OUT`     |                                               |
| 45           | STASH           | `C`      | `OUT`     |                                               |
| 46           | STASH           | `D`      | `OUT`     |                                               |
| 47           | STACK           | `A`      | `TOP`     |                                               |
| 48           | STACK           | `B`      | `TOP`     |                                               |
| 49           | MASK            | -        | `MASK`    |                                               |
| 50           | MASK            | -        | `BIT`     |                                               |
| 51           | UOP             | `A`      | `NEG`     |                                               |
| 52           | UOP             | `A`      | `NOT`     |                                               |
| 53           | UOP             | `A`      | `BSW`     |                                               |
| 54           | UOP             | `B`      | `NEG`     |                                               |
| 55           | UOP             | `B`      | `NOT`     |                                               |
| 56           | UOP             | `B`      | `BSW`     |                                               |
| 57           | PACK            | -        | `ADDR`    | Input address forwarded unchanged.            |
| 58           | *reserved*      |          |           |                                               |
| 59           | *reserved*      |          |           |                                               |
| 60           | *reserved*      |          |           |                                               |
| 61           | BITCNT          | -        | `POP`     |                                               |
| 62           | BITCNT          | -        | `CLZ`     |                                               |
| 63           | BITCNT          | -        | `CTZ`     |                                               |

## Memory Interface

A single `MEM` FU handles both loads and stores in issue order. A later ready operation must not overtake an earlier pending operation.

```
inputs:  READ, WRITE, CHUNK, MASK
outputs: CHUNK (loads only)
```

`READ` and `WRITE` carry full byte addresses. The FU aligns each address down to its 8-byte beat (`base = address & ~7`). Chunks are 64-bit little-endian values; byte lane 0 is the least significant byte.

A load consumes one `READ` token and produces the corresponding `CHUNK`. It does not require store inputs. A store consumes one `(WRITE, CHUNK, MASK)` tuple atomically, only when all three tokens are available; it does not require a `READ` token and produces no output. Store address, data, and mask cannot be consumed separately or paired with tokens from different stores.

`MASK` is an inverted 8-bit byte-lane mask: bit N = 0 writes lane N, and bit N = 1 preserves it. A mask of `0x00` writes the full chunk; `0xFF` preserves all bytes. Use the `ZERO` source for a full-width store.

If read and write trigger together, semantics are **read-before-write**: the load returns the chunk from before the store is applied. Using the same address for both operations allows a memory cell to be swapped with a supplied value:

```
# STASH_A holds the address; STASH_B holds the replacement chunk.
STASH_A.OUT -> MEM.READ, STASH_A.OUT -> MEM.WRITE, STASH_B.OUT -> MEM.CHUNK, ZERO -> MEM.MASK [sync]
# MEM.CHUNK yields the old contents; memory now contains the replacement.
```

## PACK / UNPACK Interface

```
PACK:   (Address, Type, Value) -> (Address, Chunk, Mask)
UNPACK: (Address, Type, Chunk) -> (Value)
```

The assembly port names are `ADDR`, `TYPE`, `VALUE`, `CHUNK`, and `MASK`, as listed in the tables above. Both FUs consume their three inputs atomically.

`Type` is `enum(u8, i8, u16, i16, u32, i32, u64, i64)`, encoded in this order:

| TYPE | Type | Bytes | Required alignment |
| ---- | ---- | ----- | ------------------ |
| 0    | u8   | 1     | None               |
| 1    | i8   | 1     | None               |
| 2    | u16  | 2     | 2 bytes            |
| 3    | i16  | 2     | 2 bytes            |
| 4    | u32  | 4     | 4 bytes            |
| 5    | i32  | 4     | 4 bytes            |
| 6    | u64  | 8     | 8 bytes            |
| 7    | i64  | 8     | 8 bytes            |

Other type values and misaligned addresses trap. Naturally aligned values never cross chunk boundaries.

`PACK` takes the low bits of `VALUE` selected by `TYPE` and places them into the chunk starting at byte lane `ADDR[2:0]`. Other chunk bytes are zero. Its mask clears the target lane bits and sets all other lane bits. Signed and unsigned types of the same width pack identically. `PACK.ADDR` forwards the full input address unchanged. Its three outputs share a generation and must be routed together when all are needed:

```
PACK.ADDR -> MEM.WRITE, PACK.CHUNK -> MEM.CHUNK, PACK.MASK -> MEM.MASK [sync]
```

`UNPACK` selects the typed value from `CHUNK` starting at byte lane `ADDR[2:0]`. It sign-extends signed types and zero-extends unsigned types to 64 bits. Both 64-bit types return the full chunk unchanged. Extension is handled by `UNPACK`; there is no separate extension FU.

A narrow load uses `MEM.CHUNK -> UNPACK.CHUNK`, with the original address and desired type supplied to `UNPACK.ADDR` and `UNPACK.TYPE`. A narrow store uses `PACK` followed by the three moves shown above.
