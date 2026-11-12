# Sink selector

`mdma_sink_selector` presents one payload to an addressed target. The
combinational inputs are `i_data` and `i_address`. The default `WIDTH=64`
and `SELECT_BITS=6` give 64 targets. Target `n` uses
`o_data[n*WIDTH +: WIDTH]` and `o_valid[n]`.

Exactly one target is valid for each address, and that target sees the
input word. Receivers use data only when their valid bit is high.
The surrounding logic qualifies valid with the transfer enable and
handles FIFO acceptance.

| `IMPLEMENTATION` | Payload and selection |
| --- | --- |
| `0`, shared bus (default) | Each target sees the shared word and compares its own address with the shared address lanes. The default bus is 70 bits wide. |
| `1`, direct data mux | A central mux tree selects one valid lane. Each target muxes between the input word and zero using that valid lane. |
| `2`, select-lane mux | The same central mux tree selects the valid lane. Each target sees the shared word. |

`just rtl-test` exercises all three modes. `just selector-measure` routes
64-bit builds with 4, 16, and 64 targets on the ECP5 −8. Pass a shape
such as `64x16` to measure that shape alone.

The measurements use the same pin-driven scan harness as the ALUs.
Each target has its own scan-loaded capture enable, held stable while
the measurement clock runs. Native ECP5 capture flops preserve the
individual target loads and keep the selector on their data inputs.
The report audits those flops, checks that the scan logic stays outside
the measurement-clock critical path, and compares the mapped selector
cones and whole-build resources. Routed Fmax is a characterization.
Reports, tool logs, and bitstreams are written to `build/rtl/selector`.
