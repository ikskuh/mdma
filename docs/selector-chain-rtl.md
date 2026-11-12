# Selector chain integration

The three isolated fixtures connect a 64-way sink selector and a 64-way
source selector around UOP, a FIFO, or a FIFO on each side of UOP. UOP uses
the UOP_A operation set. Sink address zero enters the active chain. Source
addresses zero through two select NEG, NOT, and BSW, respectively. The
FIFO-only chain returns its head at source address zero.

Each FIFO is a four-entry LUT RAM. The buffered UOP result FIFO holds
all three siblings and their valid bits in one entry. Taking any valid
sibling retires the entry. The bypass switch controls whether a full FIFO
can replace its head on the same edge. The two-FIFO fixture sets both
FIFOs to the same mode.

Each unused sink has a scan-loaded ready bit and an independently
enabled capture bank. Each unused source has its own scan-loaded data
and valid bit. The fixture exposes which source was taken, including
the active sibling lanes. This preserves the selector fan-in and fan-out
while exercising a single ALU or FIFO chain. Scan loading and readback
run on their own clock. The timing report covers the measurement clock
between launch registers, the chain, and capture registers.

Readback is indexed. With the measurement clock stopped, shift the desired
capture bit index into the low 13 scan bits and pulse `scan_clk` with
`scan_load` high to put that captured bit on `scan_out`. The next stimulus
load replaces the scan input before the measurement clock resumes.

`just rtl-test` simulates the 72 combinations. `just selector-chain-measure`
routes the same combinations on the ECP5 −8. There are 18 direct UOP
builds, 18 FIFO builds, and 36 buffered UOP builds. The sweep characterizes
Fmax and writes reports, routed netlists, and bitstreams to
`build/rtl/selector-chains`. The baseline for each chain uses the shared
sink bus, classic source mux, registered UOP, and bypass where applicable.
