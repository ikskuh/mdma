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
| 26         | EXT             |          | `IN`      |                                                             |
| 27         | BITCNT          |          | `IN`      |                                                             |
| 28         | SEL             | `A`      | `COND`    | Selector condition, `0` is false, else true.                |
| 29         | SEL             | `A`      | `TRUE`    | Selector truthy value Used when `COND` is not 0.            |
| 30         | SEL             | `A`      | `FALSE`   | Selector falsy value. Used when `COND` is 0.                |
| 31         | SEL             | `B`      | `COND`    | Selector condition, `0` is false, else true.                |
| 32         | SEL             | `B`      | `TRUE`    | Selector truthy value Used when `COND` is not 0.            |
| 33         | SEL             | `B`      | `FALSE`   | Selector falsy value. Used when `COND` is 0.                |
| 34         | LOAD            |          | `ADDR`    | When written, loads a value from written address in memory. |
| 35         | STORE           |          | `ADDR`    |                                                             |
| 36         | STORE           |          | `CHUNK`   |                                                             |
| 37         | STORE           |          | `MASK`    |                                                             |
| 38         | PACK            |          | `ADDR`    |                                                             |
| 39         | PACK            |          | `VALUE`   |                                                             |
| 40         | PACK            |          | `SIZE`    |                                                             |
| 41         | EXTRACT         |          | `ADDR`    |                                                             |
| 42         | EXTRACT         |          | `CHUNK`   |                                                             |
| 43         | EXTRACT         |          | `SIZE`    |                                                             |
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
| 38           | LOAD            | -        | `CHUNK`   |                                               |
| 39           | PACK            | -        | `CHUNK`   |                                               |
| 40           | PACK            | -        | `MASK`    |                                               |
| 41           | EXTRACT         | -        | `VALUE`   |                                               |
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
| 57           | EXT             | -        | `ZX8`     |                                               |
| 58           | EXT             | -        | `ZX16`    |                                               |
| 59           | EXT             | -        | `SX8`     |                                               |
| 60           | EXT             | -        | `SX16`    |                                               |
| 61           | BITCNT          | -        | `POP`     |                                               |
| 62           | BITCNT          | -        | `CLZ`     |                                               |
| 63           | BITCNT          | -        | `CTZ`     |                                               |

