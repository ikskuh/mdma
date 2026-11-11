# Functional-unit FIFO

`mdma_fifo` implements a single-clock queue with the same
`data`/`valid`/`take` handshake as an ALU port. Each instance sets its own
`DEPTH`, `WIDTH`, and `IMPLEMENTATION`. The defaults are four entries of
64 bits in flip-flop storage. Depths of four or more can use any integer,
and the queue exposes exactly that capacity. A wider word can carry a
whole group of simultaneous FU results.

| Implementation | Payload storage |
| --- | --- |
| `0` | Flip-flops |
| `1` | Distributed LUT RAM |
| `2` | Synchronous block RAM |

A push or pop transfers on the rising clock edge when that port's valid
and take signals are both high. An empty queue presents the first pushed
word after the accepting edge. Its head stays stable until taken. A full
queue can accept a push on the edge that pops the old head. The output
data is unspecified while its valid signal is low.

Reset suppresses transfers and clears the pointers and occupancy on the
rising edge. The block RAM variant reads the next head on a pop. If the
read and write addresses coincide, forwarding supplies the newly pushed
word. This covers an empty push and replacement of the only queued word.

Run `just rtl-test` for the queue-model and FU wiring tests.
`just fifo-measure` uses the ALU pin-driven harness and produces isolated
ECP5 −8 measurements and bitstreams in `build/rtl/fifo`. Its default sweep
uses 64-bit words at depths 4, 8, 16, 32, and 64, plus 128-bit words at
depth 8. Pass explicit shapes such as `just fifo-measure 64x5 1x8` to run
other configurations. The report checks payload storage mapping and
compares each RAM variant with the flip-flop baseline at the same width
and depth. The sweep reports routed Fmax as a characterization.
