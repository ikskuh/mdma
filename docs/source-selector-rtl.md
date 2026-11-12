# Source selector

`mdma_source_selector` selects one word and its validity bit. Source `n`
occupies `i_data[n*WIDTH +: WIDTH]` and `i_valid[n]`. The outputs are
`o_data` and `o_valid` from the source named by `i_address`. Its data
passes through even when its validity bit is low. The surrounding logic
handles transfers. The defaults are 64 sources of 64 bits each.

| `IMPLEMENTATION` | Datapath |
| --- | --- |
| `0`, classic mux (default) | A balanced tree of two-input muxes selects data and valid together. |
| `1`, wired OR with muxed enables | A central mux tree generates one-hot enables. Each source masks its word and valid bit with its enable, and the lanes combine with a bitwise OR. |
| `2`, wired OR with address lanes | Each source compares its address with the shared address lanes to enable its contribution. The default uses six address lanes, 64 payload lanes, and one valid lane. |

`just rtl-test` exercises all implementations. `just source-selector-measure`
builds and routes all three at 4, 16, and 64 sources on the ECP5 −8.
Use a shape such as `64x16` to measure a subset. Reports, logs, routed
netlists, and bitstreams go under `build/rtl/source-selector`.

The pin-driven scan harness gives each input an independent launch register.
The audit checks that every launch bit reaches the selector outputs and that
scan logic stays outside the measurement-clock critical path. The report
compares the mapped selector cones and uses Yosys LUT4 counts and nextpnr
resource totals. It counts each unique wire identifier in the final routed
netlist's `ROUTING` attributes once, including the harness and clock routes.
Fmax is characterized without a frequency floor.
