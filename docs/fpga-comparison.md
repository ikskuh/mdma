# RISC-V FPGA CPU comparison

Initialize the submodules and generate the upstream cacheless VexRiscv
configuration with Java and sbt. Yosys needs the `read_slang` frontend for
the RISC-V builds.

```sh
git submodule update --init
just vexriscv-rtl
just compare-fpga --route
just compare-fpga --summary
```

Use `RISCV_GCC` and `RISCV_OBJCOPY` to select a GCC toolchain with RV32
multilibs. The default executable prefix is `riscv64-elf-`.
`VERILATOR` selects the RTL simulator. `VEXRISCV_RTL` can point to an
existing Verilog file from the same generator. Pass core names to build
only those variants and use
`--coremark-only` to skip the C examples. Set `MDMA_ECP5_ROUTER` to select
an alternate nextpnr router.

Each build uses the existing board SoC, UART, and 256 KiB byte-masked BRAM.
The default is one shared RAM port with data requests taking priority. A
32-bit adapter selects the appropriate half of each 64-bit response and
maps write strobes to the correct byte lanes. The RISC-V startup and
CoreMark driver write timing and exit markers through the adapter.
`just rtl-test` checks the shared BRAM in both port modes.
The [legacy MDMA measurements](ecp5-legacy-stats.md) are archived separately.

| Core | Configuration | Compiler |
| --- | --- | --- |
| Ibex | Fast multiply, branch target ALU, writeback stage, FF register file, no instruction cache | GCC `-O2 -march=rv32im -mabi=ilp32` |
| PicoRV32 | Fast multiply, divide, barrel shifter | GCC `-O2 -march=rv32im -mabi=ilp32` |
| SERV | One-bit datapath and SRAM register file, no MDU | GCC `-O2 -march=rv32i -mabi=ilp32`, with software multiply/divide |
| VexRiscv | Upstream `GenFullNoMmuNoCacheSimpleMul` | GCC `-O2 -march=rv32im -mabi=ilp32` |

CoreMark uses the repository's checked single iteration over the pinned
kernels. CoreMark/MHz is one million divided by the iteration clocks.
CoreMark/s scales that number to the 25 MHz reference clock and to the
achieved frequency when routing completes. Routed frequencies use the
LFE5UM5G-85F-8BG381 with unconstrained I/O. Each result directory contains
the simulation logs, program images, and any route and utilization reports.

Example counts cover the whole checked executable from boot through halt.
GCC can fold work with compile-time inputs, such as `sum_to(10)`. Image
bytes include the boot offset and initialized data. BRAM counters count
physical requests, including speculative fetches. A fetch port wait counts
a request held off by the shared BRAM arbiter.
