# QBE backend for MDMA

Build the standalone backend with a host C compiler and the pinned QBE
submodule initialized.

```sh
git submodule update --init
just qbe-build
build/qbe-mdma -o program.mdma program.ssa
python src/assembler/mdma_asm.py program.mdma -o program.bin
```

Supply all QBE IL modules for the image in one invocation. The entry point is
`export function w $main()`. Its result is stored in `__mdma_result` before the
program halts. When running the simulator directly, set `--memory-size` to
the binary size plus 65,536 bytes for the software stack.

The backend supports integer and pointer operations, typed and unaligned
accesses, constant-size `blit`, phi nodes, and direct and indirect scalar
calls. Fixed-size allocations belong in the entry block. The supported subset
excludes floating-point operations, aggregate and variadic calls, TLS, and
dynamic allocations.

## Scheduling

Scheduling is enabled by default with the embedded ECP5 board profile.
Use `--schedule PATH` to select another profile, such as
`src/qbe/profiles/simulator.conf`, or `--no-schedule` to use the original
serial lowering. Each profile supplies one `UNIT LATENCY ISSUE_INTERVAL`
row per unit instance, in CPU clocks. `#` starts a comment. Latency measures
from dispatch of the last operand to the first readable result. For
`MEM_WRITE` it measures through the write acknowledgement. Issue interval
estimates the steady-state spacing between requests accepted by the unit.
The ECP5 estimates use the 1:1 memory and math clock configuration and
include transport. Memory timing varies with SRAM waits and arbitration.

Set `stack_push_ordered yes` only when an accepted push is visible as the
next instruction's stack top even if an older entry is already readable.
Omitting the setting limits each STACK to one live compiler temporary.
Latency estimates guide scheduling. The compiler checks ordering and
capacity separately and uses hardware readiness to tolerate stalls.

The optimizer promotes eligible scalar locals and schedules independent
moves backward from their consumers. Local values can flow directly
between units or through STASH and STACK. Values live across block and
call boundaries stay in frame slots. Calls, phi edges, and unproven-alignment
memory accesses use the original lowering.

`just qbe-test` compiles and runs the small IL fixtures under `tests/qbe/`.
They use the same leading `# expect mem64` and `# expect fault` directives as
the assembly fixtures. Compiler-error cases use `# expect error <text>`.
A fixture can include other modules by placing `*.lib.ssa` files beside it.

`just qbe-coremark` requires cproc on PATH or through the `CPROC` environment
variable. It runs the same kernel driver natively and on MDMA using the
pinned CoreMark list, matrix, and state kernels. One iteration with the
2,000-byte performance configuration must yield CRCs `0xe714`, `0x1fd7`,
and `0x8e3a`.
It reports the ticks for the iteration and for the whole run separately.
The whole run takes about 34 million simulator ticks and has a 50 million
tick limit.

`just qbe-coremark-ecp5` runs the same workload on the ECP5 board RTL. It uses
Verilator on PATH or through the `VERILATOR` environment variable. The
testbench runs all clock domains at the same frequency and uses the board's
default two-clock SRAM read and write delays. It measures CPU clocks between
the iteration entry and a marker before the final CRC checks, then reports
one million divided by that count as the RTL CoreMark/MHz estimate. This is
a single-iteration kernel run using simulated SRAM.

Each CoreMark recipe uses its matching profile by default. Pass
`--no-schedule` for the baseline or `--schedule PATH` for a custom profile.
The runner reports image size and code efficiency before timing the run.
