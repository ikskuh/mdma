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

The backend emits fixed MDMA templates in IL order. Temporaries and return
addresses occupy memory-backed frames. It supports integer and pointer
operations, typed and unaligned accesses, constant-size `blit`, phi nodes,
and direct and indirect scalar calls. Fixed-size allocations belong in the
entry block. Floating-point operations, aggregate and variadic calls, TLS,
and dynamic allocations are outside the supported subset.

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

`just qbe-coremark-ecp5` runs the same image on the ECP5 board RTL. It uses
Verilator on PATH or through the `VERILATOR` environment variable. The
testbench runs all clock domains at the same frequency and uses the board's
default two-clock SRAM read and write delays. It measures CPU clocks between
the iteration entry and a marker before the final CRC checks, then reports
one million divided by that count as the RTL CoreMark/MHz estimate. This is
a single-iteration kernel run using simulated SRAM.
