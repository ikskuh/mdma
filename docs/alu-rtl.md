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
The [FIFO RTL](fifo-rtl.md) implements this interface with selectable storage.

| Parameter | Availability | Operand acceptance |
| --- | --- | --- |
| `REGISTERED=0` | Combinational once all operands are valid | On the same edge as result retirement |
| `REGISTERED=1` (default) | After the edge that accepts the operands | When the result register is empty or its previous group retires |

Both modes support one group per clock when operands and consumers are ready.
Reset suppresses transfers while asserted and clears the registered result on
the rising edge. In passthrough mode, downstream take feeds back to upstream
take combinationally. The surrounding wiring must avoid combinational loops.

## Divider implementations

DIV and DIVS use `IMPLEMENTATION` in place of `REGISTERED`. Mode `0`
is combinational passthrough, mode `1` registers the complete result, and
mode `2` is the default pipelined implementation. `SIGNED_OP` selects
signed or unsigned division independently.

In mode `2`, each bit in `CUTS` inserts an elastic register after the
corresponding restoring divide step. The least significant bit follows the
first step and bit 63 must be set. `SIGN_INPUT` adds an input stage for
magnitude conversion. The unstalled latency is the number of register cuts
plus `SIGN_INPUT`. Signed quotient and remainder correction uses the held
final stage. The divider accepts and retires one operand group per clock
once the pipeline is full, provided the consumer keeps taking results.
Backpressure fills the available stages, and reset clears all in-flight
validity. The divider preserves result order across normal results and faults.

PACK, UNPACK, DIV, and DIVS also expose `o_fault`. A fault makes only that
source valid for its group. The data is `1` for an invalid type, `2` for a
misaligned typed address, and `3` for division by zero. PACK and UNPACK check
the full type value before alignment. Faults stall and retire like any result.

## Tests and ECP5 measurements

`just rtl-test` checks each ALU implementation against the Python simulator
and runs separate latency and throughput checks. `just alu-measure` builds
registered and passthrough modes for the other ALUs and the selected
pipelined modes for DIV and DIVS. Pass `--include-divider-baselines` to include
the divider's comparison builds. To measure candidate cuts, select DIV or
DIVS and pass `--cuts` with comma-separated step numbers ending in 64.
`--seed` changes the placement seed. `--limb-bits` selects a carry-select
limb width, with `0` using the ordinary subtractor.

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
router and listed in each generated configuration. The default sweep requires
a routed bitstream and an FU Fmax of at least 75.0 MHz for each selected
implementation. Divider comparison builds retain their timing results and
artifacts for reference.

The runner writes Markdown and JSON reports, tool logs, and bitstreams under
`build/rtl/alu` by default. Resource totals include the harness. Synthesis
times are wall-clock measurements. The FU Fmax values describe isolated
builds on the ECP5 -8 device.

### Four-entry FIFO integration

`just rtl-test` also connects each ALU to a four-entry LUT RAM FIFO on
every operand and one four-entry result FIFO. Each result entry contains
the sibling words and their valid bits. Taking any valid sibling retires
the entire entry, including a fault entry. Operands queue independently,
then enter the ALU as a complete group.

`just alu-integration-measure` builds the direct ALU and the buffered
fixture with the same pin harness and placement settings. Each comparison
reports routed Fmax, the critical path, Yosys LUT4 usage, unique final
routed wire segments, and resource and synthesis-time deltas. Production
modes must meet 65 MHz routed Fmax. Reports and bitstreams go under
`build/rtl/alu-integration`. Use `--include-divider-baselines` to also
measure the original registered and passthrough divider modes as timing
references.

Pass `--compare-bypass` to compare full-FIFO replacement on and off
for each ALU mode. All operand and result FIFOs in a fixture use the same
bypass setting. The matrix gives routed MHz, synthesized LUT4s, and
unique routed wires. The default output directory for this comparison
is `build/rtl/alu-bypass`.

The [selector-chain fixtures](selector-chain-rtl.md) extend this measurement
to full-width sink and source selectors around UOP and the FIFOs.

### Divider depth search

The selected cuts and placement seeds live in `mdma_div_config.vh`. The
shortest passing configurations in the sweep use the ordinary subtractor
and fold signed input magnitude conversion into the first divide stage.

| Unit | Clocks | Seed | Routed Fmax |
| --- | ---: | ---: | ---: |
| DIV | 19 | 3 | 76.49 MHz |
| DIVS | 20 | 6 | 78.66 MHz |

The best routed 16-, 17-, and 18-clock candidates reached 65.32, 63.59, and
70.88 MHz for DIV and 65.55, 61.85, and 62.28 MHz for DIVS. The tested
19-clock DIVS routes either timed out or failed. The 16-bit carry-select
trials increased routing pressure and yielded lower frequencies. Some
DIVS candidates were limited by the backpressure path. In the selected
routes, both critical paths end at partial remainder registers.
