# ADHD CPU — Architecture Specification
# Autonomous Data-Hungry Dispatch

## Overview

This architecture is a statically-scheduled, VLIW-style dataflow machine operating on 64-bit words. Rather than a conventional register file, all inter-unit communication is mediated by FIFOs. Functional units (FUs) are autonomous: they fire independently whenever their input FIFOs are non-empty, producing results into output FIFOs. Instructions describe data routing — moving tokens from source FIFOs to sink FIFOs — rather than invoking FUs directly.

The design is inspired by Transport-Triggered Architectures (TTA) and Synchronous Dataflow (SDF) graphs, but deliberately pragmatic: the FU set is irregular, multi-output results share a generation, and the instruction word includes predication and immediate facilities.

---

## Execution Model

### Functional Units

FUs operate autonomously. When all input FIFOs of an FU are non-empty, the FU fires: it dequeues one token from each input, computes all outputs simultaneously, and enqueues one result token per output FIFO. FUs are not invoked by instructions — instructions only route data to and from them.

**Multi-output generation semantics:** All output FIFOs of an FU share a generation. When *any* output source is consumed by an instruction, the entire generation is retired. Unconsumed outputs from that generation are silently dropped. This prevents output FIFOs from accumulating unconsumed tokens when only a subset of outputs is needed, which would otherwise cause backpressure stalls.

### Instruction Execution

Each instruction encodes up to 5 source/sink pairs. Execution is governed by two flags:

**`synchronized = true`:** All pairs fire atomically. The instruction does not begin until all sources are simultaneously non-empty and all sinks are simultaneously not full. All transfers then commit in a single step. This is the safe default for reasoning about instruction-level ordering.

**`synchronized = false`:** Pairs fire independently as soon as their individual source/sink readiness conditions are met. The PC does not advance until all pairs have completed. This enables daisy-chaining within an instruction: pair 0 fires and produces a result that enables pair 1's source, which then fires, enabling pair 2, etc.

**Staging semantics:** Each unique source FIFO is dequeued at most once per instruction, regardless of how many pairs reference it. The dequeued token is held in a per-instruction staging slot for the duration of the instruction. All pairs reading the same source see the same staged value. Ephemeral sources (ZERO, CONST, PC+1) are never dequeued — they generate a fresh token on each read.

In both modes, deadlock (a pair never becoming ready) is a programming error equivalent to an infinite stall.

### Predication

When `predication = true`, one token is consumed from COND before the instruction fires. If the token is zero, all moves are suppressed (but the token is consumed regardless). Any non-zero value permits execution. `COND` is write-only — there is no source address for it. Condition tokens are produced by routing CMP or other boolean-producing outputs to `COND`.

### Immediates

When `immediate = true`, `pairs[4]` is not interpreted as a source/sink pair but as a 12-bit immediate value, zero-extended to 64 bits. This value is yielded by the `CONST` source for the duration of this instruction. When `immediate = false`, `CONST` yields `1`.

There is exactly one immediate value per instruction. An instruction requiring multiple distinct constant values must stage them across multiple instructions using STASH FIFOs. This is a deliberate encoding constraint: the 12-bit immediate field occupies the fifth pair slot, and there is no room for more than one without reducing the maximum pair count below four.

---

## Instruction Encoding

64-bit instruction word:

```
[63]    reserved      : u1 == 0
[62]    predication   : bool
[61]    synchronized  : bool
[60]    immediate     : bool
[59:0]  pairs[0..4]   : [5]u12
```

Each pair:

```
[11:6]  src   : u6    // source FIFO address (absolute)
[5:0]   dst   : u6    // sink FIFO address (see delta encoding below)
```

If `immediate = true`, `pairs[4]` is reinterpreted as a 12-bit zero-extended immediate value rather than a source/sink pair. The instruction then has at most 4 active pairs.

### Sink Address Encoding

Sink addresses use a staged additive (delta) encoding. `dst0` is an absolute address; subsequent `dst` fields are offsets from the previously resolved address. This structurally eliminates duplicate sink addresses within an instruction — they are unrepresentable, not merely illegal.

```
dst0_abs =  dst0
dst1_abs =  dst0_abs + dst1 + 1
dst2_abs =  dst1_abs + dst2 + 1
dst3_abs =  dst2_abs + dst3 + 1
dst4_abs =  dst3_abs + dst4 + 1   // omitted if immediate == true
```

All additions saturate at 63 (DISCARD). This guarantees:

```
dst0_abs <= dst1_abs <= dst2_abs <= dst3_abs <= dst4_abs
```

Equality only occurs when saturation has collapsed multiple pairs to DISCARD. The compiler sorts pairs by ascending resolved sink address before encoding.

---

## Memory Model

The ADHD CPU uses a **unified 64-bit chunk-based memory model**. All architectural memory transfers are exactly 64 bits wide.

### Design Decisions

**The data bus is architecturally fixed at 64 bits.** Memory always transfers full 8-byte chunks. There are no separate narrow load/store units. This simplifies the memory subsystem and matches the machine's dataflow style: memory does full-beat transfers, and helper FUs handle lane extraction and packing. The old per-size LSU model (LOAD8/16/32/64, STORE8/16/32/64) was replaced because it duplicated interface surface area and complicated both the spec and simulator without any architectural benefit.

**Memory is little-endian.** Byte lane 0 is the least significant byte of each 64-bit chunk. Lane 7 is the most significant byte.

**Addresses are aligned down to 8-byte beats.** `LOAD` and `STORE` both compute `base = addr & ~7` internally. The low 3 address bits are ignored by the memory array, but remain architecturally significant: `PACK` and `EXTRACT` use them for lane selection. Passing the full address token into all memory-related FUs is cleaner than splitting "aligned base" and "byte offset" at the call site.

**Narrow memory operations are synthesized, not primitive.** A narrow load is expressed as `LOAD → EXTRACT`. A narrow store is expressed as `PACK → STORE`. This decomposition fits naturally into the asynchronous daisy-chain execution model: `LOAD.CHUNK → EXTRACT.CHUNK` within a single async instruction completes a narrow load without a register file, because the chunk token is forwarded directly from one FU's output to the other's input staging slot within the same instruction.

**Store masks use inverted polarity.** `mask bit N = 0` means write byte lane N. `mask bit N = 1` means preserve byte lane N. The inversion is intentional: it makes the common full-width store free, because `ZERO` (always available as a built-in source) routes directly to `STORE.MASK` without materializing any constant. If the polarity were conventional ("1 = write"), a full 64-bit store would require `mask = 0xFF`, which would force unnecessary constant materialization in the common case. In an ISA with scarce immediate space, this tradeoff is not worth it.

**Natural alignment is required for PACK and EXTRACT.** Misaligned accesses trap. Accesses never cross chunk boundaries because all sub-word accesses are naturally aligned by construction. Only `u8/i8` carries no alignment restriction.

### Narrow Load / Store Patterns

Narrow byte load:
```
# async instruction: LOAD feeds EXTRACT in the same cycle
LOAD.CHUNK -> EXTRACT.CHUNK, CONST -> LOAD.ADDR [imm=<addr>]
# then in next instruction (CONST carries the addr):
CONST -> EXTRACT.ADDR, CONST -> EXTRACT.SIZE [imm=<addr>]  # size=6 for u8
```

Because the address and size constants differ, they must be staged across two instructions. Alternatively, if addr is already in a STASH, it can be read twice. A full async daisychain for a byte load at a known address is:

```
# instr 0: issue load, stage addr and size into STASH
CONST -> LOAD.ADDR, CONST -> STASH_A.IN  [imm=0x100]
CONST -> STASH_B.IN                       [imm=6]      # u8
# instr 1: extract (async: LOAD.CHUNK arrives, feeds EXTRACT)
LOAD.CHUNK -> EXTRACT.CHUNK, STASH_A.OUT -> EXTRACT.ADDR, STASH_B.OUT -> EXTRACT.SIZE
# result available as EXTRACT.VALUE
```

Signed 16-bit load (size = 5 for i16):
```
# same pattern, size=5 instead of 6
```

32-bit store (size = 2 for u32):
```
# instr 0: pack the value
CONST -> PACK.ADDR, CONST -> PACK.VALUE, CONST -> PACK.SIZE [imm=<addr>]
# ... (PACK.VALUE and PACK.SIZE need separate instructions for distinct immediates)
# instr N: store
PACK.CHUNK -> STORE.CHUNK, PACK.MASK -> STORE.MASK, STASH_A.OUT -> STORE.ADDR
```

Full 64-bit store (no PACK needed — mask is zero):
```
ZERO -> STORE.MASK, <value_src> -> STORE.CHUNK, <addr_src> -> STORE.ADDR
```
`ZERO` routes directly to `STORE.MASK`, expressing a full-width store with no extra instruction. This is the primary motivation for the inverted mask polarity.

SWIZZLE8 byte reversal (reverse all 8 bytes):
```
# pattern for byte reversal: sel_i = 7-i
# sel_0=7, sel_1=6, ..., sel_7=0 → pattern[23:0] = 0b000_001_010_011_100_101_110_111 = 0x0F8A28
CONST -> SWIZZLE8.PATTERN [imm=0xFA8]   # truncated example; full pattern via STASH
<value_src> -> SWIZZLE8.VALUE
# result: SWIZZLE8.VALUE
```

---

## Functional Unit Reference

### ARITH (×2: A, B)
```
inputs:  lhs, rhs
outputs: add, sub
latency: 1 cycle
```

### LOGIC (×2: A, B)
```
inputs:  lhs, rhs
outputs: and, or, xor
latency: 1 cycle
```

### SHIFT (×2: A, B)
```
inputs:  val, cnt
outputs: lsl, lsr, asr, rol, ror
latency: 1 cycle
```
`asr` is arithmetic right shift. `lsl`/`lsr` are logical (zero-fill). `rol`/`ror` are rotation.

### CMP (×1)
```
inputs:  lhs, rhs
outputs: eq, lt, lts, lte, ltes
latency: 1 cycle
```
`lt`/`lte` are unsigned. `lts`/`ltes` are signed. `gt`/`gte` are expressed by swapping operands.

### UOP (×2: A, B)
```
inputs:  in
outputs: neg, not, bswap
latency: 1 cycle
```

### EXT (×1)
```
inputs:  in
outputs: zext8, zext16, sext8, sext16
latency: 1 cycle
```
Generic datapath extension of the low 8 or 16 bits to 64 bits. Distinct from EXTRACT: EXT operates on arbitrary in-flight values; EXTRACT operates on memory chunks.

### BITCNT (×1)
```
inputs:  in
outputs: popcnt, clz, ctz
latency: 1 cycle
```

### MUL (×1), MULS (×1)
```
inputs:  lhs, rhs
outputs: low, high
latency: 2 cycles
```
Full 64×64 → 128-bit multiply. MUL unsigned, MULS signed.

### DIV (×1), DIVS (×1)
```
inputs:  lhs, rhs
outputs: rem, quot
latency: 7 cycles
```
DIV unsigned, DIVS signed. Division by zero is implementation-defined.

### MASK (×1)
```
inputs:  n
outputs: mask, bit
latency: 1 cycle
```
`mask` = `(1 << n) - 1`. `bit` = `1 << n`.

### SEL (×2: A, B)
```
inputs:  cond, true, false
outputs: out
latency: 1 cycle
```
All three inputs are consumed unconditionally on every firing.

### LOAD (×1)
```
inputs:  addr
outputs: chunk
latency: 4 cycles
```
Reads a 64-bit little-endian chunk from the 8-byte beat containing `addr`. Computes `base = addr & ~7`, reads `mem[base .. base+7]` as a little-endian u64. The low 3 bits of addr do not affect which beat is loaded; they are passed to EXTRACT for lane selection. Memory faults trap.

### STORE (×1)
```
inputs:  addr, chunk, mask
outputs: (none)
latency: 4 cycles (serialized: one memory op per cycle)
```
Writes selected byte lanes of `chunk` to the 8-byte beat containing `addr`. Computes `base = addr & ~7`. Byte-lane mask polarity: **bit N = 0 means write lane N; bit N = 1 means preserve lane N**. `mask = 0x00` writes all 8 bytes; `mask = 0xFF` is a no-op. For a full 64-bit store, route ZERO to STORE.MASK. Memory faults trap.

### PACK (×1)
```
inputs:  addr, value, size
outputs: chunk, mask
latency: 1 cycle
```
Converts a scalar value into a 64-bit `chunk` and an 8-bit inverted byte-lane inhibit `mask` suitable for use with STORE. The `size` input selects the width and signedness via an enum:

| size value | type | bytes | align required |
|---|---|---|---|
| 0 | u64 | 8 | addr[2:0] == 0 |
| 1 | i64 | 8 | addr[2:0] == 0 |
| 2 | u32 | 4 | addr[1:0] == 0 |
| 3 | i32 | 4 | addr[1:0] == 0 |
| 4 | u16 | 2 | addr[0] == 0 |
| 5 | i16 | 2 | addr[0] == 0 |
| 6 | u8  | 1 | none |
| 7 | i8  | 1 | none |

Values ≥ 8 are reserved and trap. Misaligned accesses trap. Signed and unsigned variants of the same width behave identically for PACK — only width matters for bit placement — but both are present for ISA symmetry with EXTRACT and for future typed analysis.

Lane placement uses `addr[2:0]` to determine the starting byte lane within the chunk. All non-target bytes in `chunk` are zero. `mask` has all non-target lane bits set (= preserve) and target lane bits cleared (= write).

### EXTRACT (×1)
```
inputs:  addr, chunk, size
outputs: value
latency: 1 cycle
```
Converts a 64-bit memory chunk into a scalar value. Uses the same size enum and alignment rules as PACK. Selects bytes starting at lane `addr[2:0]` from `chunk`. Unsigned sizes zero-extend the result to 64 bits; signed sizes sign-extend. `u64` and `i64` return the full chunk unchanged.

EXTRACT is the load-side mirror of PACK. LOAD always delivers the full 64-bit beat; EXTRACT turns it into the requested typed scalar. This removes the old rule that all loads implicitly zero-extend and require downstream EXT for signed loads.

### SWIZZLE8 (×1)
```
inputs:  value, pattern
outputs: value
latency: 1 cycle
```
Byte permutation. Interprets `pattern[23:0]` as 8 × 3-bit selectors. Output byte lane `i` = input byte lane `pattern[3*i +: 3]`. Lane 0 = bits [7:0]; lane 7 = bits [63:56]. Upper bits of pattern above bit 23 are ignored.

The 3-bit selector form is sufficient to express any arbitrary byte permutation, splat, byte-swap, or endianness conversion on a 64-bit word. A 4-bit extended form would allow zero-fill lanes but is not needed for the common cases, and keeping the pattern to 24 bits keeps it within reach of a single 12-bit immediate followed by a shift.

### STASH (×4: A, B, C, D)
```
inputs:  in
outputs: out
depth:   8 tokens
```
FIFO queue. General-purpose temporary storage, analogous to virtual registers. Required for passing multiple distinct constant values across instructions that have only one immediate slot.

### STACK (×2: A, B)
```
inputs:  in (push)
outputs: out (pop)
```
LIFO queue. Used for call/return address management and recursive state.

---

## Control Flow

### Unconditional Jump
```
CONST -> PC [imm=<target>]
```

### Conditional Jump (using predication)
```
# produce condition token, then:
CMP.LT -> COND
CONST -> PC [pred] [imm=<target>]
```

### Conditional Select Jump (using SEL)
```
CMP.EQ    -> SEL_A.COND
CONST     -> SEL_A.TRUE   [imm=<addr_true>]
<false>   -> SEL_A.FALSE
SEL_A.OUT -> PC
```

### Call / Return
```
# call:
PC.NEXT -> STACK_A.PUSH, CONST -> PC [imm=<target>]

# return:
STACK_A.TOP -> PC
```

---

## Source Table

| # | Name | Description |
|---|------|-------------|
| 0 | ZERO | Constant 0 (unique color token per use) |
| 1 | CONST | 1 normally; zero-extended 12-bit imm if `immediate=true` |
| 2 | PC.NEXT | Address of next instruction |
| 3 | ARITH_A.ADD | |
| 4 | ARITH_A.SUB | |
| 5 | ARITH_B.ADD | |
| 6 | ARITH_B.SUB | |
| 7 | LOGIC_A.AND | |
| 8 | LOGIC_A.OR | |
| 9 | LOGIC_A.XOR | |
| 10 | LOGIC_B.AND | |
| 11 | LOGIC_B.OR | |
| 12 | LOGIC_B.XOR | |
| 13 | SHIFT_A.LSL | |
| 14 | SHIFT_A.LSR | |
| 15 | SHIFT_A.ASR | |
| 16 | SHIFT_A.ROL | |
| 17 | SHIFT_A.ROR | |
| 18 | SHIFT_B.LSL | |
| 19 | SHIFT_B.LSR | |
| 20 | SHIFT_B.ASR | |
| 21 | SHIFT_B.ROL | |
| 22 | SHIFT_B.ROR | |
| 23 | CMP.EQ | |
| 24 | CMP.LT | Unsigned |
| 25 | CMP.LTS | Signed |
| 26 | CMP.LTE | Unsigned |
| 27 | CMP.LTES | Signed |
| 28 | MUL.LO | |
| 29 | MUL.HI | |
| 30 | MULS.LO | |
| 31 | MULS.HI | |
| 32 | DIV.REM | |
| 33 | DIV.QUO | |
| 34 | DIVS.REM | |
| 35 | DIVS.QUO | |
| 36 | SEL_A.OUT | |
| 37 | SEL_B.OUT | |
| 38 | LOAD.CHUNK | Full 64-bit chunk from memory beat |
| 39 | PACK.CHUNK | Positioned chunk ready for STORE |
| 40 | PACK.MASK | Inverted byte-lane inhibit mask for STORE |
| 41 | EXTRACT.VALUE | Lane-extracted, sign/zero-extended scalar |
| 42 | SWIZZLE8.VALUE | Byte-permuted result |
| 43 | STASH_A.OUT | |
| 44 | STASH_B.OUT | |
| 45 | STASH_C.OUT | |
| 46 | STASH_D.OUT | |
| 47 | STACK_A.TOP | |
| 48 | STACK_B.TOP | |
| 49 | MASK.MASK | `(1 << n) - 1` |
| 50 | MASK.BIT | `1 << n` |
| 51 | UOP_A.NEG | |
| 52 | UOP_A.NOT | |
| 53 | UOP_A.BSW | |
| 54 | UOP_B.NEG | |
| 55 | UOP_B.NOT | |
| 56 | UOP_B.BSW | |
| 57 | EXT.ZX8 | |
| 58 | EXT.ZX16 | |
| 59 | EXT.SX8 | |
| 60 | EXT.SX16 | |
| 61 | BITCNT.POP | |
| 62 | BITCNT.CLZ | |
| 63 | BITCNT.CTZ | |

---

## Sink Table

| # | Name | Description |
|---|------|-------------|
| 0 | PC | Sets next PC |
| 1 | ARITH_A.LHS | |
| 2 | ARITH_A.RHS | |
| 3 | ARITH_B.LHS | |
| 4 | ARITH_B.RHS | |
| 5 | LOGIC_A.LHS | |
| 6 | LOGIC_A.RHS | |
| 7 | LOGIC_B.LHS | |
| 8 | LOGIC_B.RHS | |
| 9 | SHIFT_A.VAL | |
| 10 | SHIFT_A.CNT | |
| 11 | SHIFT_B.VAL | |
| 12 | SHIFT_B.CNT | |
| 13 | CMP.LHS | |
| 14 | CMP.RHS | |
| 15 | MUL.LHS | |
| 16 | MUL.RHS | |
| 17 | MULS.LHS | |
| 18 | MULS.RHS | |
| 19 | DIV.LHS | |
| 20 | DIV.RHS | |
| 21 | DIVS.LHS | |
| 22 | DIVS.RHS | |
| 23 | MASK.N | |
| 24 | UOP_A.IN | |
| 25 | UOP_B.IN | |
| 26 | EXT.IN | |
| 27 | BITCNT.IN | |
| 28 | SEL_A.COND | |
| 29 | SEL_A.TRUE | |
| 30 | SEL_A.FALSE | |
| 31 | SEL_B.COND | |
| 32 | SEL_B.TRUE | |
| 33 | SEL_B.FALSE | |
| 34 | LOAD.ADDR | Full address token; FU aligns to `addr & ~7` |
| 35 | STORE.ADDR | Full address token |
| 36 | STORE.CHUNK | 64-bit chunk to write |
| 37 | STORE.MASK | Inverted byte-lane inhibit mask (0=write, 1=keep) |
| 38 | PACK.ADDR | Full address; low 3 bits select lane |
| 39 | PACK.VALUE | Scalar value to pack |
| 40 | PACK.SIZE | Size enum (0–7); values ≥ 8 trap |
| 41 | EXTRACT.ADDR | Full address; low 3 bits select lane |
| 42 | EXTRACT.CHUNK | 64-bit chunk from LOAD |
| 43 | EXTRACT.SIZE | Size enum (0–7); values ≥ 8 trap |
| 44 | SWIZZLE8.VALUE | Input value to permute |
| 45 | SWIZZLE8.PATTERN | 24-bit selector pattern in low bits |
| 46 | STASH_A.IN | |
| 47 | STASH_B.IN | |
| 48 | STASH_C.IN | |
| 49 | STASH_D.IN | |
| 50 | STACK_A.PUSH | |
| 51 | STACK_B.PUSH | |
| 52 | COND | Write-only; non-zero = execute, zero = inhibit |
| 53–62 | *(reserved)* | |
| 63 | DISCARD | Always accepts; value is dropped |

---

## Design Notes / Open Issues

- **Single immediate per instruction.** There is exactly one 12-bit immediate slot per instruction (occupying the fifth pair slot when `immediate=true`). Instructions that need multiple distinct constant values must stage them across multiple instructions via STASH. This is the intended programming model — STASH FIFOs function as the ISA's register file analog, and the constraint forces explicit pipelining of constant setup.
- **Large immediates.** Values exceeding 12 bits must be loaded from memory or synthesized via ARITH/LOGIC chains. For very large constants, store them in the program's data section and load via LOAD+EXTRACT.
- **COND across calls.** Intentionally permitted. A condition token pushed before a call and consumed in the callee is a valid boolean argument-passing mechanism. Unintentional clobbering is a programming error.
- **Memory faults.** LOAD and STORE trap on fault. Trap handling is currently unspecified (halt and catch fire). The simulator displays `⚠ TRAP` in the status bar.
- **FIFO depths.** All FU input/output FIFO depths are implementation-defined (simulator: depth 8). Deadlock analysis and buffer sizing is a compiler/toolchain responsibility.
- **Division by zero.** Implementation-defined; simulator yields zero.
- **Atomic memory ops.** Out of scope; architecture is single-core.
- **Multi-word arithmetic.** No carry chain between ARITH units. 128-bit addition via multi-pop output semantics deferred to a future extension.
- **Memory serialization.** Only one LOAD or STORE may start per clock cycle. Multiple memory FUs queued in the same clock compete; one wins and the rest stall until their turn.