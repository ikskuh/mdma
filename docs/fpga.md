# Legacy MDMA ECP5 softcore

This reference describes the MDMA RTL and commands at the `ecp5-legacy`
tag. The [RISC-V benchmark](fpga-comparison.md) uses the shared board SoC
from the current checkout.

The [ECP5 architecture decision record](ecp5-architecture-decision.md)
summarizes the current design, measured tradeoffs, and timing status.

The ECP5 issues up to five FIFO moves on one CPU edge. Its internal
instruction stream prefetches raw words independently of execution. Two
interleaved distributed RAM banks expose the first two unread words and
their bus errors. The decoder can consume zero, one, or two words per clock.

The banks form a rolling window. During initial fill the stream can reserve
every slot. Once full, it makes room for a fetch only by evicting a consumed
word beyond the configured history. The lookahead budget includes the head
word, unread words, and reservations for pending or accepted requests.
`MDMA_STREAM_WORDS` sets the total capacity to 8, 16, or 32 words and
defaults to 16. `MDMA_STREAM_AHEAD_WORDS` sets the lookahead and defaults
to half the total, giving eight words each of lookahead and history.
A split must leave at least two words on each side. These overrides work
with the FPGA build and both RTL simulation runners.

The CPU decoder consumes one opcode and, for an extended immediate, a second
word when available. Both buffered words enter the registered execute stage
together, giving `CONST` zero additional latency. With only the opcode ready,
execution starts immediately and `CONST` remains unavailable until the next
word arrives. Independent moves proceed; synchronized moves retain their
all-ready rule. `PC_NEXT` is known from the opcode's address and mode.
The CPU alone records a missing constant and consumes it before another
opcode. Waiting for this word is outstanding work, not a deadlock.

A PC move captures its target once. Once that move has committed and the
current immediate has been captured, the stream registers the target for
a one-clock lookup. A resident target moves the decoder cursor while the
prefetch frontier stays in place. After a backward seek, existing lookahead
can exceed the configured budget until the head catches up. The remaining
moves retain their original `CONST` and `PC_NEXT` while target prefetch runs. Target instructions execute after the
current instruction retires. Halt uses the same barrier before draining FUs.
Fetch errors travel with words and fault only when needed by the decoder;
speculative fall-through errors disappear on redirect.

The stream fetches directly from CPU-clock BRAM through a native 64-bit port.
A request transfers when valid and ready are both high. Its ordered reply,
including any address error, is sampled on the next clock. The instruction
port supplies up to one raw word per clock. Extended instructions consume
two words, so sustained instruction throughput depends on the instruction mix.

A redirect miss clears the rolling window and waits one cycle for any
discarded reply before issuing the next request. A resident hit keeps
in-flight reads. The stream reserves a slot before presenting a request, so
a stalled request retains space even if a backward seek moves the head.
Stores leave buffered instruction words intact. Self-modifying code is
unsupported.

FIFO status selection uses three LUT4 tiers.
Each of the five transfer slots selects a source through four local 16-way
muxes and a final 4-way mux. The five selected words and sink enables are
registered. On the following edge, each sink writes its selected slot while
dispatch can accept five more moves. CPU-clock operand banks count reserved
writes before their data reaches RAM. Each functional unit runs independently
as soon as its operands and result space are ready.

The ECP5 has 45 independent operand FIFOs and 27 independent result banks.
The operand/result banks map to 52 block RAMs. Program and data memory adds
128, for 180 of the target’s 208 blocks in either port mode. The remaining
FIFO banks and the MEM request queue use distributed RAM. The `COND` FIFO
queues eight entries, storing one truth bit per entry.
Narrow operands use local distributed RAM. CMP, BITCNT, and PACK store
6, 21, and 136 bits per result generation and expand their fields to 64-bit
words at the transport interface.
Sibling sources share one wide result entry and their pop requests are ORed.
The six STASH and STACK ports use their own direct storage banks for both
input and output, with 16 entries each. Pushes become readable on the next
clock by forwarding from the transfer registers. COND can forward to the
next predicated instruction when its FIFO is empty. STASH counts accepted
writes at dispatch and updates its RAM write pointer at writeback. Its read
pointer advances independently on pops. STACK reserves its top address at
dispatch and writes that RAM entry at writeback. Both storage units forward
pending writes when they are the next value to read. Ordinary FUs pop operands
in parallel, compute siblings in parallel, and enqueue the result generation
on the same edge in the default fast mode. Operands can come directly from
writeback when no older token is queued.

The four math units have separate clock inputs on `mdma_ecp5.math_clk[3:0]`.
Bits 0 through 3 are MUL, MULS, DIV, and DIVS. Each has dedicated dual-clock
operand and result FIFOs with synchronized Gray pointers. Supply all four
clock inputs, or connect selected inputs to the same clock on the board.
The full and empty flags use Gray-code comparisons in their local domains.
BRAM and UART MMIO run on the CPU clock.

Each functional-unit family has its own Verilog module. Elaboration connects
the selected operation to the common FIFO and pipeline signals. Signed and
unsigned math instances share their family's RTL through a constant parameter.

## Simulation and build

```sh
just rtl-test
just rtl-benchmark
MDMA_BRAM_IMAGE=program.bin just fpga-build
```

The behavior suite compares halt, fault codes, and memory against the
independent Python simulator. The separate benchmark reports five-wide issue,
FU latency, and the time between a storage push and its visibility.
Timing changes do not affect behavior-suite pass criteria.

Set `MDMA_FAST_ALU=1` for writeback operand forwarding and direct ALU result
enqueue with a two-stage SHIFT. Set `MDMA_FAST_ALU=2` to also use a single
SHIFT compute stage. Mode `2` is the default, with a 25 MHz CPU timing target.
Mode `0` selects the registered implementation.
The setting applies to the build script, RTL tests, and ECP5 CoreMark runner.

```sh
just rtl-test
just rtl-benchmark
just qbe-coremark-ecp5
```

In the forwarding modes, a CPU-clock ALU can consume its last operand on the
writeback edge and enqueue the computed sibling generation on that edge.
An operand still behind an older FIFO entry waits for that entry. Normal
FIFO push and pop accounting also applies when writeback supplies the head.
Result FIFO space gates consumption, and invalid PACK/UNPACK requests raise
the usual faults before a result is enqueued.

The ALU benchmark reports both dispatch-to-readiness and dispatch-to-dependent
use with buffered instructions. Four consecutive requests measure the
issue interval.
Mode 1 measures two clocks for 14 ALU instances and three clocks for SHIFT A/B.
Mode 2 measures two clocks for all 16 ALU instances. Both modes sustain one
request per clock and consecutive instructions carrying five transfers.

### BRAM performance

The following runs use the same ECP5 scheduling profile and 16-word stream
configuration. The workload excludes setup and teardown. All CoreMark CRCs
and example results pass.

| Board memory | CoreMark workload clocks | CoreMark/MHz | `sum_to` workload clocks | `mix_loop` workload clocks |
| --- | ---: | ---: | ---: | ---: |
| External SRAM | 12,344,287 | 0.08100913 | 81 | 1,890 |
| Single-port BRAM | 6,359,670 | 0.15724086 | 48 | 1,600 |
| Dual-port BRAM | 6,349,569 | 0.15749100 | 48 | 1,600 |

CoreMark's 103,967 instruction-port wait clocks in single-port mode overlap
mostly with execution or buffered fetch. Dual port removes those waits and
saves 10,101 timed clocks.

On the LFE5UM5G-85F-8BG381, the placement comparison used a 25 MHz target,
unconstrained reference pins, and the same three seeds and nextpnr settings.

| BRAM mode | CPU MHz, seeds 1 / 2 / 3 | Median MHz |
| --- | --- | ---: |
| Single port | 39.74 / 44.36 / 46.05 | 44.36 |
| Dual port | 41.65 / 41.84 / 43.78 | 41.84 |

The higher placement median makes single port the provisional default.
Router2 trials timed out with conflicts remaining, so routed timing is
unconfirmed. The median single-port placement's critical CPU path starts
at the CPU-side MULS result FIFO pointer. It passes through move readiness
and dispatch and ends at a slot payload register. Interconnect accounts
for 19.29 ns of its 22.54 ns estimated delay.

### Historical SRAM rolling buffer depth sweep

The sweep used the same assembled workloads and board model at each depth.
All CoreMark CRCs passed. Timing used ECP5-85 CABGA381 speed grade −7, a
25 MHz CPU target, default fast ALUs, and the same local nextpnr build with
two threads, parallel placement refinement, and unconstrained reference
pins. Router2 trials on seed 1 reached their 240-second limit with
conflicts remaining. The table uses placement estimates throughout.

| Capacity / lookahead | CoreMark clocks | CPU MHz, seeds 1 / 2 / 3 | Median MHz | Estimated iterations per second | `sum_to` clocks | `mix_loop` clocks |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| 64, hard flush (`799733a`) | 12,051,683 | 30.20 / 29.80 / 30.24 | 30.20 | 2.506 | 146 | 1,799 |
| 8 / 4 | 12,470,387 | 26.98 / 30.62 / 24.97 | 26.98 | 2.164 | 96 | 1,991 |
| **16 / 8** | **12,344,287** | **30.87 / 29.17 / 26.28** | **29.17** | **2.363** | **81** | **1,890** |
| 32 / 16 | 12,368,878 | 28.25 / 30.71 / 27.58 | 28.25 | 2.284 | 81 | 1,860 |

This sweep selected 16 words with eight words of lookahead. It
ranks first among the rolling buffers by median CPU Fmax times CoreMark/MHz.
Compared with the hard-flush baseline, it shortens `sum_to(10)` by 65 clocks
and reduces estimated CoreMark throughput by 5.7%. CoreMark has 15,358
resident redirects out of 213,576, while every one of the 11 timed
`sum_to` redirects hits. The extra lookup clock on misses accounts for
most of CoreMark's clock increase.

Both stream banks infer distributed RAM at all depths. Each rolling design
uses 1,284 distributed RAM write cells and 56 block RAMs overall, versus
1,318 and 56 in the hard-flush baseline. The median 16-word placement uses
47,884 combinational cells and 9,394 flip-flops. Its longest CPU path goes
from the STASH_B occupancy register through payload selection and redirect
control to the stream head address. The estimated delay is 34.284 ns,
including 30.530 ns of routing.

To repeat the 16-word simulation with a different split, run
`MDMA_STREAM_WORDS=16 MDMA_STREAM_AHEAD_WORDS=4 just report-status`.
The same overrides apply to `just fpga-build`. The ECP5 profiler exports
`stream_words`, `ahead_words`, `resident_redirect_hits`,
`resident_redirect_misses`, and `history_evictions`.

### Original 64-word stream measurements

`just report-status` with the raw FIFO, 4 KiB external cache, and default
fast ALUs passes all result checks. CPU, memory, and math clocks are 1:1,
with the configured board SRAM waits. Workload clocks exclude startup;
total clocks run from boot through halt.

| Workload | Previous RTL workload clocks | Stream RTL workload clocks | Stream RTL total clocks |
| --- | ---: | ---: | ---: |
| CoreMark | 44,908,396 | 12,051,683 | 12,912,029 |
| `sum_to(10)` | 111 | 146 | 296 |
| `mix_loop(32, 0x12345678, 0x9e3779b1)` | 4,149 | 1,799 | 1,997 |

RTL CoreMark/MHz increases from 0.02226755 to 0.08297596. The one-clock
simulator remains at 2,937,038 workload clocks, 3,052,575 total clocks,
and 0.34047908 CoreMark/MHz. Its `sum_to` counts are 25/31 workload/total;
`mix_loop` counts are 488/496.

The short `sum_to` run regresses: its frequent jumps discard prefetch, and
the cancellation, cache response, FIFO, and decode stages add target-admission
latency. CoreMark benefits from fewer instruction misses and overlapped
prefetch. Its profile records 5,431,701 empty-execute clocks (45.07%),
3,154,457 retiring clocks, and 3,465,525 waiting clocks. The cache records
4,951,016 hit lookups and 621,547 miss lookups, starting 604,880 refills. FIFO occupancy reaches 64.
The dedicated benchmark retains consecutive five-move issue and one ALU
request per clock; all 16 CPU-clock ALUs measure two clocks from dispatch
to readiness and dependent use.

### Exported instruction-throughput counters

The ECP5 board simulation emits machine-readable `PROFILE key=value` lines.
`just qbe-coremark-ecp5` prints them and instructions/clock (IPC) and
clocks/instruction (CPI). `just report-status` also prints BRAM and stall
tables for CoreMark, `sum_to`, and `mix_loop`. The Python RTL runner's optional
`profile` dictionary receives these counters while its result tuple stays
unchanged. All counters cover the same timed workload interval as its score.

BRAM counters count accepted instruction reads (including speculative
fetches), data reads, and data writes. An instruction port wait is a clock
when a valid instruction request loses arbitration. I-cache hits, misses,
and refills are unavailable with direct BRAM fetch. Resident stream hits and
misses continue to count redirects that can or cannot reuse buffered words.

The following counters partition workload clocks without overlap:

| Counter | Meaning |
| --- | --- |
| `retired` | A completed instruction, including one skipped by predication. |
| `const_stall` | The active instruction could finish if `CONST` were ready; all other required sources, sinks, and predication are ready. Includes constant-capture delay when that prevents completion. |
| `instruction_stall` | Execute is empty and the next instruction cannot be admitted, excluding redirect lookup and cancellation. |
| `redirect_stall` | Execute is empty during redirect lookup or cancellation. Work hidden by an active instruction does not count here. |
| `execute_wait` | Other active-instruction waits, including FU/predicate waits concurrent with a missing constant. |
| `decode_bubble` | Execute is empty and an instruction is being admitted on this clock. |

Their sum equals `clocks`, and IPC is `retired / clocks`. The bench asserts
this identity on every successful run.
`const_stall_events` and `instruction_stall_events` count distinct runs of
stall clocks. `const_fifo_empty` counts active-instruction clocks waiting for
an absent extended word even when another FU also blocks completion;
`constant_wait` additionally includes word-capture clocks. These availability
counters can overlap execution waits and must not be added to the partition.

The original 64-word stream’s CoreMark run records 903,318 CONST stalls, 4,633,187 next-instruction
stalls, 205,239 exposed redirect clocks, 2,562,207 other execute waits, and
593,275 decode bubbles. Together with 3,154,457 retirements these account for
all 12,051,683 workload clocks. IPC is 0.26174411 (CPI 3.8205), and cache miss
rate is 11.15%. There are 208,516 CONST-stall episodes, 592,134 instruction-stall
episodes, and 710,634 clocks with the active instruction's constant word absent.

### Original 64-word stream synthesis and timing

The original 64-word stream synthesizes to 35,846 LUT4s, 9,201 flip-flops,
1,318 distributed-RAM primitives, and 56 block RAMs. The cache payload maps
to four block RAMs; both raw FIFO banks map to distributed RAM.
That design used a dedicated cache bench alongside the stream and decoder
benches. The current `just rtl-test` suite checks BRAM arbitration and byte
writes alongside arbitrary raw words, immediate readiness, early redirects,
and deferred fetch faults.
`just rtl-benchmark` retains separate implementation-timing checks.

For ECP5-85 CABGA381 speed grade -7 at a 25 MHz target, production-tool
placement estimates 25.44 MHz on the CPU clock. A separate detailed
placement estimates 25.18 MHz. These are placement estimates, not routed
clock guarantees. The detailed CPU path starts at the MUL operand writeback
readiness register, passes through sink selection and dispatch/redirect
control, and ends at the instruction FIFO head-address register. It has
33.015 ns estimated routing, 6.236 ns logic, and 0.460 ns clock-to-Q delay.
The multiplier datapath remains in its separate math clock domain.
Router1 timed out after 480 seconds. A corrected router2 run timed out after
240 seconds with routing conflicts remaining, so routed Fmax and a bitstream
are not available. When resuming placed JSON, its saved router setting must
also select router2; it otherwise overrides the command-line selection.

### Historical ALU measurements

The historical ALU comparison below predates removal of store-triggered instruction
cache invalidation and uses 1:1 CPU, memory, and math clocks.
The fixed-image columns use the original ECP5 scheduling profile. The
retargeted columns use the corresponding `ecp5-fast1.conf` or
`ecp5-fast2.conf`. All runs pass the list, matrix, and state CRC checks.

| ALU mode | Fixed-image CoreMark clocks | Retargeted CoreMark clocks | Retargeted CoreMark/MHz |
| --- | ---: | ---: | ---: |
| 0, registered | 45,635,321 | 45,635,321 | 0.02191285 |
| 1, split SHIFT | 45,634,841 | 45,021,254 | 0.02221173 |
| 2, single-stage SHIFT | 45,634,841 | 44,971,002 | 0.02223655 |

The fixed image spends 42,098,610 timed clocks with an empty execute slot,
3,194,395 retiring an instruction, and 342,316 waiting within an instruction
in mode 0. Mode 2 reduces the last count to 341,836. The empty-slot count
includes instruction fetch and redirect bubbles.
The profiler also partitions empty-slot clocks into `fetch_refill` while a
Wishbone refill is active, `fetch_unready` while the cache is unready without
an active refill, and `fetch_ready` while cached instruction data is ready.
Functional units can continue running during any of these clocks.
For the raw-stream implementation, `fetch_unready` and `fetch_ready` refer
to FIFO head availability. Additional counters report fetched words, cache
hits/misses, full-FIFO clocks and high-water mark, pending-constant clocks,
and redirect-to-target-admission total/maximum latency. The historical
measurements below used the earlier CPU-local cache.
With the fast profile, that 44,971,002-clock run records 37,508,908
empty-slot clocks during refills, 808,736 with an unready cache outside a
refill, and 3,154,041 with cached data ready. Active instructions retire on
3,154,457 clocks and wait on 344,860 clocks.

The same hand-assembly harness measures `sum_to(10)` at 122 clocks with either
fast mode, including cold instruction fetch, and four clocks per warm
continuing iteration. Mode 0 takes 149 clocks and seven clocks per warm
iteration. `mix_loop(32)` falls from 4,785 to 4,416 clocks with either fast
mode and returns `0x41090bb9`. Both routines issue zero data RAM accesses.

Synthesis maps all three modes to 52 block RAMs and 1,140 distributed RAM
primitives. Mode 0 uses 32,562 LUT4s and 12,321 flip-flops. Mode 1 uses
33,458 LUT4s and 8,577 flip-flops. Mode 2 uses 33,652 LUT4s and 8,271
flip-flops.

The initial matched ECP5-85K −7 runs used the fixed reference pins, a 42 MHz target,
and seeds 1 and 2. Installed router2 aborted during setup. Router1 baseline
trials timed out after 600 seconds. A local router2 build reached routing,
but baseline and mode 2 trials still had conflicts at their 300-second limits.
These runs establish no routed Fmax comparison.

A diagnostic placement for mode 2 estimates 31.00 MHz. Its longest CPU path
starts in sibling replay data, passes through predicate and dispatch control,
and ends in the CPU-side DIVS result FIFO read-data register. The path crosses
nine LUT stages and six local mux arcs, with 28.684 ns of estimated routing
delay, 3.115 ns of logic, and 0.460 ns of clock-to-Q delay.

After promoting mode 2 to the default and lowering the target to 25 MHz,
fresh synthesis again maps 33,652 LUT4s, 8,271 flip-flops, and 52 block RAMs.
The production-tool placement estimates 29.04 MHz; a separate detailed
placement estimates 30.13 MHz. Both clear the target. The complete build
reached routing but timed out at its 480-second limit, so a routed Fmax and
bitstream remain unavailable from this run.

Use the core-only Icarus model to measure RTL clocks with an ideal memory port:

```sh
python src/simulator/simulator.py program.bin --rtl-timing ecp5
```

The build uses Yosys and nextpnr and writes its reports and bitstreams under
`build/rtl/`. The reference build targets the LFE5UM5G-85F-8BG381 (ECP5-5G, 85K,
381-ball caBGA, speed grade −8). Set `MDMA_ECP5_LPF` to the board's pin constraints before building a
bitstream to load on hardware. Without it, nextpnr assigns reference pins.
`MDMA_ECP5_FREQ` overrides the 25 MHz timing target for clocks without a
specific constraint.

### Historical ECP5-85 speed grade −7 timing

The cache-coherence build before FIFO width compaction estimated 33.35 MHz for the CPU, 67.02 MHz
for memory, and 70.28, 59.36, 57.86, and 84.73 MHz for MUL, MULS, DIV, and
DIVS respectively. The 29.99 ns CPU path runs from the MULS result FIFO
read pointer through dispatch to the MUL RHS FIFO write-pointer enable.
It crosses ten LUT4 stages and three additional mux-only arcs. The FIFO
status selector accounts for three of the LUT4 stages. Interconnect accounts
for an estimated 26.41 ns of the path.
The 14.92 ns memory path runs from the instruction reply FIFO write pointer
through arbitration to the SRAM data-register enable. Full-core routing is
pending.

An isolated, routed −7 comparison of the signed divide engine measured
156.15 MHz with two clocks per quotient bit and 120.89 MHz with one clock per
bit. The shorter implementation reduces DIV and DIVS from 131 to 67 FU
clocks and improves isolated time per division by about 1.5×.

### FIFO storage sweep

The ECP5-85K −7 sweep used one fixed reference pin assignment, a 42 MHz
placement target, and three HeAP seeds. It ran before the FIFO width
compaction. None of the six finalist routes completed, so the sweep did not
select an alternate mapping.

| Mapping | First-pass median CPU estimate | Best CPU estimate | Block RAMs | Flip-flops |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 32.07 MHz | 33.05 MHz | 67 | 12,634 |
| All operand banks in distributed RAM | 29.77 MHz | 33.46 MHz | 0 | 10,595 |
| ARITH operands in registers | 33.65 MHz | 35.40 MHz | 59 | 14,422 |
| MUL RHS and MULS results in registers | 28.45 MHz | 31.36 MHz | 67 | 14,170 |

With packed FIFOs, the unregistered two-stage selector uses 42,114 combinational sites.
The direct-select experiment registered each sink's source index at decode
and retained the same FIFO and sibling replay behavior. It passed RTL
simulation, but required 179,757 combinational sites. The ECP5-85K has
83,640, so placement could not complete.

| Compact two-stage variant | Median CPU placement estimate | Best CPU placement estimate | Combinational sites |
| --- | ---: | ---: | ---: |
| Native source muxes | 32.42 MHz | 33.59 MHz | 42,114 |
| Port masks registered in decode | 31.34 MHz | 35.49 MHz | 42,461 |
| Port masks and one-hot source selection registered in decode | 32.79 MHz | 35.09 MHz | 44,408 |
| Registered slots with one-edge STASH and STACK, physical FIFO credits | 38.45 MHz | 38.86 MHz | 42,475 |
| Registered slots with two-edge STASH and STACK | 32.37 MHz | 35.74 MHz | 42,098 |
| Registered slots with dispatch-side STASH fullness | 38.87 MHz | 39.76 MHz | 42,589 |
| Reviewed build with local operand and STACK reservations | 36.95 MHz | 39.37 MHz | 42,988 |

The best one-hot placement crosses seven LUT4 stages in 28.50 ns, with
25.06 ns attributed to interconnect. The best native-mux placement crosses
thirteen LUT4 stages in 29.77 ns, with 25.35 ns attributed to interconnect.

The best placement with dispatch-side STASH fullness estimates 25.15 ns for
the CPU path. It crosses ten LUT4 stages through CPU-side DIVS result FIFO
control and dispatch to the DIVS result read-data register. Interconnect
accounts for 21.16 ns.

The reviewed build's best seed estimates 25.40 ns from sibling replay
through predicate handling and dispatch to the CPU-side DIVS result FIFO
read-data register. It crosses five LUT4 stages and local muxes, with
22.44 ns attributed to interconnect. The other two seeds terminate in
retirement and decode logic. The best seed's routing trial timed out with
unresolved congestion, so these figures remain placement estimates.

### Registered FIFO endpoints and payload width

These ECP5-85 −7 trials used three matched placement seeds with the same
pin assignment and 42 MHz placement target. The FIFO trials changed the
ordinary CPU-clock FU operand and result banks. STASH, STACK, COND and MEM
kept their existing storage and forwarding. The CDC trial also registered
the CPU-side math result-valid flags.

| Build | Median CPU estimate | Best CPU estimate | Combinational sites | Flip-flops | Block RAMs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Current 64-bit datapath | 36.95 MHz | 39.37 MHz | 42,988 | 12,321 | 52 |
| LUTRAM without extra endpoints | 33.34 MHz | 33.35 MHz | 43,577 | 10,829 | 6 |
| LUTRAM with registered ingress and head | 31.11 MHz | 31.18 MHz | 47,051 | 18,624 | 6 |
| LUTRAM with registered head and reused ingress | 30.33 MHz | 31.21 MHz | 46,924 | 14,843 | 6 |
| Registered ingress and head plus math result-valid registers | 29.98 MHz | 34.13 MHz | 46,940 | 18,664 | 6 |
| 32-bit payload sizing prototype | 39.01 MHz | 42.42 MHz | 29,405 | 9,077 | 38 |

The endpoint trials passed the behavior fixtures and sustained consecutive
five-transfer dispatches. The double-ended variant adds one clock from
acceptance to first visibility per staged FIFO. Its longest placed paths
still cross dispatch into the CPU-side math result FIFOs.

The 32-bit prototype narrows ordinary source and writeback payloads. It
keeps the 64-bit instruction format, fetch path and direct PC writes.
Its measurements size a narrower transport. A functional 32-bit ISA
would also need native arithmetic widths and explicit rules for wide
addresses, literals and memory chunks. The prototype's best placement
passes the 42 MHz target and its route attempt timed out with unresolved
congestion.

## Memory and board interfaces

`mdma_cpu` exposes independent native instruction and data request ports.
Both use 64-bit byte addresses. The data port also carries write data and
active-high byte enables. Requests hold their address and controls until
accepted. The SoC checks the entire address before converting it to a BRAM
word index. The memory range is `0x00000`–`0x3ffff`. Data-port UART
addresses take precedence over the BRAM bounds check.

The board uses a single 32,768 × 64-bit BRAM array. In single-port mode a
BRAM data access takes priority over instruction fetch. In dual-port mode
instruction fetch and data access can complete together. A write with any
enabled byte lane delays an instruction read of the same word until a later
clock. Byte masks use native write enables. A MEM swap sends an ordered
read followed by a write and returns the original read data.

`MDMA_BRAM_IMAGE` is an assembled little-endian binary loaded at address
zero through the FPGA bitstream. The build pads the image with zeros to
256 KiB and rejects empty or oversized binaries. In the historical BRAM
sweep, CoreMark used a 127,264-byte image plus a 65,536-byte stack reserve.
The CoreMark comparison at `42a5a3a` used a 37,088-byte image. The
simulation runners use the same image conversion.
`MDMA_BRAM_PORTS=1` (default) or `2` selects the port mode for FPGA builds
and RTL simulations.

Halt drains complete operand bundles and discards unread results as needed
to make space. A fault can still stop the drain.

The default UART bit period is 104 clocks, approximately 115200 baud at
12 MHz. `CLOCKS_PER_BIT` controls that ratio. The byte handshake in
`mdma_soc` can also connect directly to an external USART module.

| Byte address | Register | Behavior |
| --- | --- | --- |
| `0xfffffff0` | Status | Bit 0 is RX available. Bit 1 is TX ready. |
| `0xfffffff8` | Data | A read waits for and consumes one byte. A store with lane 0 enabled waits for TX space and sends the low byte. |

[Serial echo example](../examples/serial-echo.mdma)

## Measured functional-unit latency

The Icarus measurements count the first operand pop through result enqueue,
inclusive. The ECP5 math measurements use the individual FU clocks and exclude
the FIFO pointer synchronization needed for CPU visibility. MEM measurements
use a core-only mock that replies on the request edge. The board BRAM adds
one clock per memory beat, so a swap adds two clocks before contention.

| Unit or operation | Registered mode 0 | Default fast mode 2 |
| --- | ---: | ---: |
| STASH / STACK | Readable on the next clock | Readable on the next clock |
| ARITH, LOGIC, CMP, MASK, UOP, BITCNT, SEL, PACK, UNPACK, SWIZZLE8 | 3 CPU clocks | 1 CPU clock |
| SHIFT | 4 CPU clocks | 1 CPU clock |
| MUL / MULS | 7 FU clocks | 7 FU clocks |
| DIV / DIVS | 67 FU clocks | 67 FU clocks |
| MEM store / load / swap | 2 / 3 / 4 CPU clocks | 2 / 3 / 4 CPU clocks |
