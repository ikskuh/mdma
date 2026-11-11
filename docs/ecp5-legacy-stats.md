# ECP5 legacy statistics

Snapshot of `ecp5-legacy` (`8d16c177e0463f24031dceab152c216ac1b9d80b`), captured 2026-11-11.
See the [architecture decision record](ecp5-architecture-decision.md) and
the [machine-readable snapshot](ecp5-legacy-stats.json) for every exported
counter, all FPGA resource classes, per-instance RAM and DSP counts,
all 70 fixture timings, and placement reports.

The workload runs used Verilator 5.054 and patched cproc at `d1c53dd`
with QBE's ECP5 schedule. The CoreMark kernels came from the pinned
`v1.01` submodule. The list, matrix, and state CRCs were `e714`, `1fd7`,
and `8e3a`. Icarus 13.0 ran the core microbenchmarks. Yosys 0.69+150
and nextpnr-ecp5 0.11.1-31 targeted LFE5UM5G-85F-8BG381 at 25 MHz.
The default run uses ALU mode 2, one BRAM port, a 16-word stream with
eight words of lookahead, and 1:1 CPU and math clocks.

## Default workload and image statistics

Workload clocks cover a CoreMark iteration or the named function.
Total clocks cover boot through halt. Image bytes exclude zero padding.
The simulator uses one-clock FU latency and issue intervals.
Move density uses five slots per encoded instruction word. Inline
immediates occupy one slot and extended immediate words occupy five.

| Workload | Target | Workload clocks | Total clocks | CoreMark/MHz | Image bytes | Used move slots | Unused / total move slots |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| CoreMark | Simulator, one clock | 925,741 | 973,584 | 1.08021574 | 34,976 | 50.75% | 9,985 / 20,275 |
| CoreMark | ECP5 RTL | 2,303,676 | 2,419,245 | 0.43408882 | 37,088 | 46.55% | 11,545 / 21,600 |
| sum_to(10) | Simulator, one clock | 25 | 31 | — | 112 | 60.00% | 24 / 60 |
| sum_to(10) | ECP5 RTL | 58 | 96 | — | 112 | 60.00% | 24 / 60 |
| mix_loop(32, 0x12345678, 0x9e3779b1) | Simulator, one clock | 456 | 464 | — | 288 | 53.53% | 79 / 170 |
| mix_loop(32, 0x12345678, 0x9e3779b1) | ECP5 RTL | 1,567 | 1,609 | — | 288 | 53.53% | 79 / 170 |

| CoreMark static image | One-clock simulator | ECP5 RTL |
| --- | ---: | ---: |
| Instruction bundles | 3,645 | 3,971 |
| Extended immediate words | 410 | 349 |
| Inline immediate bundles | 1,030 | 1,091 |
| Predicated bundles | 126 | 126 |
| Synchronized bundles | 1,291 | 1,251 |
| Data words | 315 | 315 |
| Padding bytes | 16 | 8 |

At the 25 MHz reference frequency, the CoreMark cycle count projects
**10.85 iterations/s**.
A routed frequency for the legacy core is unavailable.

CoreMark image SHA-256 before padding

`98af12770723b47bfadc4adf022ad98e02a752618dc61a0d909ad3f7998b4013`

## Every default RTL performance counter

Direct BRAM fetch has no instruction cache. The raw `cache_enabled` flag is
zero, and I-cache hit, miss, and refill counts are unavailable. The stream
redirect miss counter measures whether a target word is resident in the
rolling window. BRAM instruction reads include speculative requests.
The timed clock partition is `retired` plus `const_stall`,
`instruction_stall`, `redirect_stall`, `execute_wait`, and
`decode_bubble`. Aggregate and availability counters overlap this partition.

| Raw RTL counter | CoreMark | sum_to | mix_loop |
| --- | ---: | ---: | ---: |
| `clocks` | 2,303,676 | 58 | 1,567 |
| `cache_enabled` | 0 | 0 | 0 |
| `bram_ports` | 1 | 1 | 1 |
| `const_stall` | 15,453 | 0 | 0 |
| `instruction_stall` | 198,104 | 0 | 195 |
| `redirect_stall` | 157,299 | 10 | 161 |
| `execute_wait` | 816,949 | 12 | 658 |
| `decode_bubble` | 100,529 | 11 | 97 |
| `const_fifo_empty` | 335 | 0 | 0 |
| `const_stall_events` | 15,118 | 0 | 0 |
| `instruction_stall_events` | 66,042 | 0 | 65 |
| `empty_execute` | 455,932 | 21 | 453 |
| `retired` | 1,015,342 | 25 | 456 |
| `waiting` | 832,402 | 12 | 658 |
| `fetch_unready` | 355,403 | 10 | 356 |
| `fetch_ready` | 100,529 | 11 | 97 |
| `redirects` | 99,074 | 11 | 97 |
| `bram_instruction_reads` | 1,552,815 | 13 | 860 |
| `bram_data_reads` | 83,941 | 0 | 0 |
| `bram_data_writes` | 35,054 | 0 | 0 |
| `bram_instruction_port_wait` | 56,247 | 0 | 0 |
| `stream_full` | 0 | 0 | 0 |
| `stream_highwater` | 15 | 15 | 13 |
| `constant_wait` | 22,660 | 0 | 0 |
| `stream_words` | 16 | 16 | 16 |
| `ahead_words` | 8 | 8 | 8 |
| `resident_redirect_hits` | 26,355 | 11 | 32 |
| `resident_redirect_misses` | 72,719 | 0 | 65 |
| `history_evictions` | 635,199 | 0 | 144 |
| `window_full` | 1,204,268 | 40 | 720 |
| `redirects_admitted` | 99,074 | 11 | 97 |
| `redirect_to_admit_total` | 489,146 | 22 | 454 |
| `redirect_to_admit_max` | 7 | 2 | 6 |

| Derived measure | CoreMark | sum_to | mix_loop |
| --- | ---: | ---: | ---: |
| Instructions per clock | 0.44074861 | 0.43103448 | 0.29100191 |
| Clocks per instruction | 2.2689 | 2.3200 | 3.4364 |
| Resident redirect miss rate | 73.40% | 0.00% | 67.01% |
| Average redirect to admission, clocks | 4.937 | 2.000 | 4.680 |

## Configuration sweep

Each variant uses the same assembled workloads and compiler schedule. The table reports RTL cycles. Per-variant raw counters and simulator results are in the JSON snapshot.

| Variant | ALU mode | BRAM ports | Stream / ahead | CoreMark clocks | CoreMark total | CoreMark/MHz | sum_to clocks | mix_loop clocks | CoreMark redirect misses | CoreMark port waits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| default | 2 | 1 | 16/8 | 2,303,676 | 2,419,245 | 0.43408882 | 58 | 1,567 | 72,719 | 56,247 |
| alu0 | 0 | 1 | 16/8 | 3,068,948 | 3,218,856 | 0.32584456 | 76 | 2,114 | 70,547 | 53,756 |
| alu1 | 1 | 1 | 16/8 | 2,324,123 | 2,440,389 | 0.43026983 | 58 | 1,567 | 72,719 | 55,275 |
| dual-port | 2 | 2 | 16/8 | 2,303,122 | 2,418,664 | 0.43419324 | 58 | 1,567 | 72,719 | 0 |
| stream-8 | 2 | 1 | 8/4 | 2,359,296 | 2,475,681 | 0.42385525 | 58 | 1,695 | 79,027 | 40,739 |
| stream-32 | 2 | 1 | 32/16 | 2,273,732 | 2,388,133 | 0.43980557 | 58 | 1,567 | 67,231 | 77,206 |

On this BRAM build, 32/16 saves 29,944 CoreMark workload clocks (1.30%) and dual port saves 554 (0.024%). The sweep measures cycles at the simulated clock. It provides no new placement or route comparison for those variants.

## Board example programs

For the examples, workload clocks cover entry to return of `main`, including self-checks. The JSON also records the distinct simulator runs, which use the simulator schedule and report kernel-call totals.

| Example | Image bytes | Main clocks | Total clocks | Retired in main | BRAM I reads | BRAM D reads | BRAM D writes | Resident redirect hits | Redirect misses |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bresenham | 1,728 | 3,999 | 4,021 | 1,774 | 2,823 | 132 | 14 | 64 | 109 |
| bubble_sort | 832 | 2,699 | 2,721 | 1,230 | 1,827 | 98 | 32 | 49 | 62 |
| crc32 | 512 | 2,350 | 2,372 | 967 | 1,867 | 9 | 0 | 9 | 140 |
| fibonacci | 272 | 1,110 | 1,132 | 502 | 76 | 0 | 0 | 94 | 6 |
| goertzel | 800 | 3,981 | 4,003 | 1,140 | 1,569 | 24 | 0 | 0 | 55 |
| mat_mul | 1,184 | 1,692 | 1,714 | 708 | 1,064 | 34 | 6 | 4 | 43 |
| memmove | 1,024 | 1,301 | 1,323 | 516 | 953 | 48 | 12 | 1 | 55 |
| mix_loop | 288 | 1,587 | 1,609 | 461 | 874 | 0 | 0 | 32 | 67 |
| quick_sort | 2,336 | 3,727 | 3,749 | 1,611 | 2,311 | 140 | 64 | 21 | 75 |
| rgba_blend | 1,456 | 2,911 | 2,933 | 858 | 1,127 | 0 | 0 | 3 | 27 |
| sha256 | 6,080 | 68,047 | 68,069 | 48,303 | 60,155 | 1,745 | 520 | 57 | 960 |
| strcpy | 656 | 412 | 434 | 170 | 307 | 17 | 5 | 1 | 16 |
| sum_to | 112 | 74 | 96 | 28 | 22 | 0 | 0 | 11 | 2 |

The hottest functions in the **one-clock simulator** are listed below. Counts attribute clocks to the function containing the current PC, excluding time spent in callees. The JSON contains the full function breakdown.

| Function | Simulator clocks | Share of timed CoreMark |
| --- | ---: | ---: |
| core_state_transition | 197,640 | 21.35% |
| matrix_mul_matrix_bitextract | 168,140 | 18.16% |
| matrix_mul_matrix | 136,064 | 14.70% |
| core_list_find | 91,781 | 9.91% |
| matrix_sum | 63,064 | 6.81% |
| core_bench_state | 59,486 | 6.43% |
| core_list_mergesort | 52,963 | 5.72% |
| crcu8 | 43,800 | 4.73% |

## FU timing and regression

Cells below show **dispatch to ready / dispatch to use / clocks for four requests**. The dispatch microbenchmark reports sampled pairs of consecutive five-transfer instructions. The word “cached” in the raw bench label refers to buffered fetch.

| FU | ALU mode 0 | ALU mode 1 | ALU mode 2 |
| --- | ---: | ---: | ---: |
| ARITH_A | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| ARITH_B | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| LOGIC_A | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| LOGIC_B | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| SHIFT_A | 6 / 6 / 4 | 3 / 3 / 4 | 2 / 2 / 4 |
| SHIFT_B | 6 / 6 / 4 | 3 / 3 / 4 | 2 / 2 / 4 |
| CMP | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| MASK | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| UOP_A | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| UOP_B | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| BITCNT | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| SEL_A | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| SEL_B | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| PACK | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| UNPACK | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |
| SWIZZLE8 | 5 / 5 / 4 | 2 / 2 / 4 | 2 / 2 / 4 |

| Dispatch test | ALU mode 0 | ALU mode 1 | ALU mode 2 |
| --- | ---: | ---: | ---: |
| cached consecutive five-transfer pairs | 2 | 2 | 2 |
| consecutive ARITH pops | 2; concurrent ARITH/LOGIC launches: 4 | 2; concurrent ARITH/LOGIC launches: 4 | 2; concurrent ARITH/LOGIC launches: 4 |
| ARITH latency | 3..3 clocks, 4 results | 1..1 clocks, 4 results | 1..1 clocks, 4 results |
| storage readable after push | STASH 1, STACK 1 clock edges | STASH 1, STACK 1 clock edges | STASH 1, STACK 1 clock edges |

The fixture latency probe measures operand pop through result enqueue, inclusive. Math clocks exclude CDC visibility, and MEM uses the core-only response model.

| Operation | Clock domain | Clocks |
| --- | ---: | ---: |
| ARITH_A | CPU | 1 |
| ARITH_B | CPU | 1 |
| LOGIC_A | CPU | 1 |
| LOGIC_B | CPU | 1 |
| SHIFT_A | CPU | 1 |
| SHIFT_B | CPU | 1 |
| CMP | CPU | 1 |
| MUL | FU | 7 |
| MULS | FU | 7 |
| DIV | FU | 67 |
| DIVS | FU | 67 |
| MASK | CPU | 1 |
| UOP_A | CPU | 1 |
| UOP_B | CPU | 1 |
| BITCNT | CPU | 1 |
| SEL_A | CPU | 1 |
| SEL_B | CPU | 1 |
| PACK | CPU | 1 |
| UNPACK | CPU | 1 |
| SWIZZLE8 | CPU | 1 |
| MEM store | CPU | 2 |
| MEM load | CPU | 3 |
| MEM swap | CPU | 4 |

Regression logs record **70/70** RTL fixtures, **113** assembler and simulator tests, and **63** QBE tests passing.

## FPGA resource inventory

The board top `mdma_ecp5` exposes four math clock inputs. The comparison top `mdma_compare_top` ties them to the CPU clock. Both use the same initialized CoreMark image, mode 2, single-port BRAM, and 16/8 stream. Site counts come from packing. Synthesized cell counts preserve the individual netlist primitive types.

| Packed resource | Available | Board top used | Comparison top used |
| --- | ---: | ---: | ---: |
| `TRELLIS_IO` | 365 | 13 | 9 |
| `DCCA` | 56 | 5 | 1 |
| `DP16KD` | 208 | 180 | 180 |
| `MULT18X18D` | 156 | 32 | 32 |
| `ALU54B` | 78 | 0 | 0 |
| `EHXPLLL` | 4 | 0 | 0 |
| `EXTREFB` | 2 | 0 | 0 |
| `DCUA` | 2 | 0 | 0 |
| `PCSCLKDIV` | 2 | 0 | 0 |
| `IOLOGIC` | 224 | 0 | 0 |
| `SIOLOGIC` | 141 | 0 | 0 |
| `GSR` | 1 | 0 | 0 |
| `JTAGG` | 1 | 0 | 0 |
| `OSCG` | 1 | 0 | 0 |
| `SEDGA` | 1 | 0 | 0 |
| `DTR` | 1 | 0 | 0 |
| `USRMCLK` | 1 | 0 | 0 |
| `CLKDIVF` | 4 | 0 | 0 |
| `ECLKSYNCB` | 10 | 0 | 0 |
| `DLLDELD` | 8 | 0 | 0 |
| `DDRDLL` | 4 | 0 | 0 |
| `DQSBUFM` | 14 | 0 | 0 |
| `TRELLIS_ECLKBUF` | 8 | 0 | 0 |
| `ECLKBRIDGECS` | 2 | 0 | 0 |
| `DCSC` | 2 | 0 | 0 |
| `TRELLIS_FF` | 83,640 | 7,874 | 7,866 |
| `TRELLIS_COMB` | 83,640 | 43,450 | 43,461 |
| `TRELLIS_RAMW` | 10,455 | 977 | 977 |

| Synthesized cell type | Board top | Comparison top | Comparison `-nowidelut` trial |
| --- | ---: | ---: | ---: |
| `$scopeinfo` | 7,368 | 7,369 | 7,369 |
| `CCU2C` | 1,683 | 1,681 | 1,681 |
| `DP16KD` | 180 | 180 | 180 |
| `L6MUX21` | 3,948 | 3,931 | 3,840 |
| `LUT4` | 33,648 | 33,667 | 33,329 |
| `MULT18X18D` | 32 | 32 | 32 |
| `PFUMX` | 8,312 | 8,268 | 5,650 |
| `TRELLIS_DPR16X4` | 977 | 977 | 977 |
| `TRELLIS_FF` | 7,874 | 7,866 | 7,866 |

Of the 180 EBRs, **128** back the 256 KiB board RAM and **52** serve full-width CPU operand FIFOs. The JSON includes pre-pack logic usage and the counts by individual operand and FU instance.

## Timing and routing

These are **placement estimates** at seed 1 with unconstrained pins. The current report has no routed Fmax or board measurement.

| Clock | Placement estimate, MHz | Target, MHz |
| --- | ---: | ---: |
| CPU | 41.99 | 25.00 |
| MUL | 72.45 | 25.00 |
| MULS | 84.23 | 25.00 |
| DIV | 78.25 | 25.00 |
| DIVS | 67.76 | 25.00 |
| Comparison top, common clock | 43.28 | 25.00 |

| Comparison routing trial | Outcome | Lowest overused wires | Last overused wires |
| --- | ---: | ---: | ---: |
| mdma | router1 stopped after more than 15 minutes | — | — |
| mdma-router2 | installed router2 aborted in setup with std::out_of_range | — | — |
| mdma-router2-fixed | local router2 build stopped with unresolved conflicts | 11,734 | 11,890 |
| mdma-spread | local router2 build, seed 2 and HeAP beta 0.72, stopped with unresolved conflicts | 24,066 | 24,066 |
| mdma-lut4 | Synthesis with `-nowidelut` and local router2 stopped with unresolved conflicts | 7,340 | 7,547 |

Router1's final progress entry showed 91,487 queued items after 1,018
seconds of routing. This queue count measures pending work. Router2's
overuse count measures wires assigned to multiple nets.

From a checkout of `ecp5-legacy`, run `just report-status` for the default
counters, `just compare-fpga mdma` for the board example workloads, and
`MDMA_FAST_ALU=<0|1|2> just rtl-benchmark` for the FU timing tables.
