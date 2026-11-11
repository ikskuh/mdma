# ALU RTL interface

The modules in `src/gateware/alu` implement the ALU sinks and sources listed in
[the ISA](functional-units.md). A/B instances use the same module with independent
parameters. For `mdma_mul` and `mdma_div`, set `SIGNED_OP=1` for MULS and DIVS.

## Transfers

| Port group | Into the ALU | Out of the ALU |
| --- | --- | --- |
| Sink `i_<name>` | `data[63:0]`, `valid` | `take` |
| Source `o_<name>` | `take` | `data[63:0]`, `valid` |

A transfer occurs on the rising edge of `clk` when both `valid` and `take` are
high. A producer holds its data and `valid` until that edge. Data is unspecified
while `valid` is low. A consumer can assert `take` in advance.

The unit accepts its operands together. Each valid result lane belongs to the
same result group. Taking any valid lane retires the group, and consumers can
sample any number of valid siblings on that edge. A take on an invalid lane
has no effect. A downstream queue stores the group as a single entry. The
minimum FIFO depths in the ISA apply to the core's external queues.

| Parameter | Availability | Operand acceptance |
| --- | --- | --- |
| `REGISTERED=0` | Combinational once all operands are valid | On the same edge as result retirement |
| `REGISTERED=1` (default) | After the edge that accepts the operands | When the result register is empty or its previous group retires |

Both modes support one group per clock when operands and consumers are ready.
Reset suppresses transfers while asserted and clears the registered result on
the rising edge. In passthrough mode, downstream take feeds back to upstream
take combinationally. The surrounding wiring must avoid combinational loops.

PACK, UNPACK, DIV, and DIVS also expose `o_fault`. A fault makes only that
source valid for its group. The data is `1` for an invalid type, `2` for a
misaligned typed address, and `3` for division by zero. PACK and UNPACK check
the full type value before alignment. Faults stall and retire like any result.

## Tests and ECP5 measurements

`just rtl-test` checks both modes of every ALU against the Python simulator and
runs separate latency and throughput checks. `just alu-measure` builds both
modes of every instance, or a subset named on the command line.

Each isolated ECP5 design has five top-level pins. The `scan_clk` domain
loads operands, valid and take bits, and reset through `scan_in`. With
`fu_clk` stopped, shift in the generated top's launch bus most significant
bit first. Hold `scan_clk` stopped during the measurement pulses. The first
`fu_clk` edge launches the bus, and subsequent edges capture the FU outputs.
With `fu_clk` stopped again, pulse `scan_clk` with `scan_load` high to load
the captured bus. Read the most significant bit on `scan_out` and shift the
remaining bits out with `scan_load` low. Keep the inactive domain stable
across clock handoffs.

The measurement domain has direct launch and capture registers on the FU
ports. The runner checks the routed FU-clock critical path for scan logic and
reports scan timing separately. The board pin locations are assigned by the
router and listed in each generated configuration. The build accepts any
routed frequency. It requires bitstreams for the local ALUs and records FPGA
build failures for MUL, MULS, DIV, and DIVS.

The runner writes Markdown and JSON reports, tool logs, and bitstreams under
`build/rtl/alu` by default. Resource totals include the harness. Synthesis
times are wall-clock measurements. The FU Fmax values describe isolated
builds on the ECP5 -8 device.
