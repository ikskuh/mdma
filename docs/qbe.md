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
the binary size plus 65,536 bytes for any addressable locals and spills.

The backend supports integer and pointer operations, typed and unaligned
accesses, constant-size `blit`, phi nodes, and direct and indirect scalar
calls. Fixed-size allocations belong in the entry block. The supported subset
excludes floating-point operations, aggregate and variadic calls, TLS, and
dynamic allocations.

## Scheduling

Scheduling is enabled by default with the embedded ECP5 board profile.
Use `--schedule PATH` to select another profile, such as
`src/qbe/profiles/simulator.conf`, or `--no-schedule` to use the original
serial lowering and memory calling convention. Each profile supplies one
`UNIT LATENCY ISSUE_INTERVAL`
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

After scalar promotion and SSA construction, the optimizer folds integer
expressions and simplifies the control-flow graph. It lays out edge copies
with their blocks, packs compatible moves with jumps, and rotates eligible
two-block loops into a guarded bottom-tested form. Rotation currently handles
at most two loop-carried values and a side-effect-free test and body.

The scheduler compares backward placement from consumers with earlier
issue of ready work on the critical path. It keeps ordered results in the
producing FU's FIFO when its queue has room. It keeps live values in FIFO homes
across control-flow edges when their lifetimes fit, and checks the queue
state at each edge. It coalesces phi copies where possible. Multi-entry
STASH layouts leave one free entry so they can rotate to the right value.
RAM holds addressable objects and spills when a FIFO layout fails. A
function whose layout remains unschedulable after bounded retries uses
frame-based lowering with the same FIFO calling convention.

### FIFO calling convention

In scheduled images the first four scalar arguments travel in STASH A–D.
Remaining arguments use RAM overflow slots, which the callee reads on entry.
Each call pushes `PC_NEXT` onto `STACK_B`. A return pops `STACK_B` into `PC`
and supplies one token in `STASH_A`, including zero for a void return.
The entry shim writes the final result to `__mdma_result`.

Bounded direct call chains keep their continuations on `STACK_B`. Recursive
or unproven chains park the current continuation in the frame across the
call. A caller may also save values on `STACK_A` across a direct leaf call
when the callee's verified peak depth leaves room. Division, `blit`, and
unaligned-access sequences preserve live values across their scratch FIFO
use. Functions with no addressable objects, spills, or saved continuations
have no memory frame.

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
The simulator has a 50 million tick limit for the whole run.

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
