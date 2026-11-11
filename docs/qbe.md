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

Direct branches and calls emit `PC_REL` with a symbolic word displacement.
The assembler selects the immediate encoding after layout. Calls that push
`PC_NEXT` return past the complete call pack. Indirect jumps, returns, and
halt use absolute `PC`.

## Scheduling

Scheduling is enabled by default with the embedded ECP5 board profile.
The profile targets the default fast ALUs, with two CPU clocks from dispatch
to dependent use and one request per clock.
Use `--schedule PATH` to select another profile, such as
`src/qbe/profiles/simulator.conf`, or `--no-schedule` to use the original
serial lowering and memory calling convention. Each profile supplies one
`UNIT LATENCY ISSUE_INTERVAL`
row per unit instance, in CPU clocks. `#` starts a comment. Latency measures
from dispatch of the last operand to the first readable result. For
`MEM_WRITE` it measures through the write acknowledgement. Issue interval
estimates the steady-state spacing between requests accepted by the unit.
The ECP5 profile assumes a 1:1 math-to-CPU clock ratio. Its memory estimates
come from the SRAM design. The BRAM benchmarks retain the profile to compare
identical machine code against that baseline.

STACK ordering is an architectural requirement. Later TOP reads observe the
newest accepted, unpopped push, waiting for its data when needed. The compiler
always relies on this rule for nested temporaries and return addresses.
Legacy profiles containing `stack_push_ordered yes` are accepted, and
`stack_push_ordered no` is rejected.
Latency estimates guide scheduling. The compiler checks ordering and
capacity separately and uses hardware readiness to tolerate stalls.

After scalar promotion and SSA construction, the optimizer eliminates
redundant RAM loads using QBE's alias analysis, folds integer expressions,
and simplifies the control-flow graph. It inlines small,
straight-line integer leaves so their operations can share the caller's
schedule. Power-of-two products become shifts, and known alignment lets
indexed loads and stores use the typed memory units directly. For a
function whose address does not escape, the compiler combines alignment
guarantees from all direct calls, including across modules. Alignment also
propagates through SSA joins and loop backedges. The scheduler lays out edge copies
with their blocks, packs compatible moves with jumps, and rotates eligible
two-block loops into a guarded bottom-tested form. Rotation currently handles
at most three loop-carried values and a pure test. The body may contain
integer selects or memory operations. Loops that combine memory operations
with multiplies retain their original structure.

For word reductions of the form `sum += n; --n` while `n != 0`, the backend
feeds the counter and accumulator through ARITH result FIFOs. The continuing
path uses two bundles. The first fans out the counter to the predicate,
decrement, and addition. The predicated backedge feeds back the accumulator
only when the loop continues. The exit discards the unused decrement and
truncates the final sum with UNPACK before returning.

The scheduler compares backward placement from consumers with earlier
issue of ready work on the critical path. It keeps ordered results in the
producing FU's FIFO when its queue has room and tries to pack all reads of the
same result into one bundle. It can keep one long result per compute FU
across an edge when the successor consumes it before a barrier. At a phi join,
all incoming results must use the same FU and result port. Other live values
use FIFO homes with checked queue state at each edge. The scheduler coalesces
phi copies where possible. Multi-entry
STASH layouts leave one free entry so they can rotate to the right value.
The scheduler packs independent STASH rotations together and restores
cyclic permutations with recirculation moves. For other permutations, it
chooses the fewest repair moves available with one scratch stack entry.
RAM holds addressable objects and spills when a FIFO layout fails. A
function whose layout remains unschedulable after bounded retries uses
frame-based lowering with the same FIFO calling convention.

The backend defers truncation through word arithmetic that depends only on
the low 32 bits. It normalizes values at consumers that need the canonical word
and compares LOGIC masks with UNPACK using the target profile. It omits a
normalization when the producing operation already guarantees that the high
bits are zero. A constant right shift used only by a mask or an extension can
be folded into UNPACK when the field fits an aligned byte, halfword, or word
lane. A synthetic address selects the lane and the type selects its width
and signedness.

An aligned access needs one memory request. When alignment cannot be proven,
the scheduler addresses the words that contain the first and last bytes.
It combines the words with shifts for loads and uses byte masks for stores.
Both requests can address the same word. In that case the second store
request masks all byte lanes. This keeps live values in the scheduler across
the access.

For leaf functions with multiple loop accesses that would benefit from known
alignment, the compiler can emit two bodies. The entry checks the required
alignment once and preserves the FIFO arguments for either body.

To pass C alignment facts to the backend, build the optional patched cproc
from a local checkout containing commit `d1c53dd`.

```sh
just qbe-aligned-cproc /path/to/cproc
CPROC="$PWD/build/cproc-alignment/cproc" just report-status
```

The frontend uses ordinary QBE `copy` instructions with reserved temporary
names `%__mdma_a2.*`, `%__mdma_a4.*`, or `%__mdma_a8.*`. Each name promises a
minimum alignment for that copied address. MDMA uses the promise when
scheduling memory requests. Unknown alignment and packed member offsets
still use the generic memory path. Stock cproc and unannotated QBE remain
supported.

Before scheduling, the compiler folds branches proved by preceding integer
comparisons or by the possible constants reaching a phi. It keeps word and
long comparisons separate and recomputes the CFG and phi inputs after folding.
Matching inclusive bounds can become an unsigned comparison of the distance
from the lower bound. A branch that only chooses the boolean value `0` or `1`
can become a straight-line expression, making small classifiers eligible for
inlining. A branch whose comparison only tests for nonzero can send the value
directly to `CPU.COND`, using the width of the original comparison. Neutral
integer operations become copies of the same width before scheduling.

Small branches that choose between pure logic values can become `SEL`
requests. The condition uses the low 32 bits, as with a QBE branch. Width
bounds propagate through integer phi nodes and pure operations. The backend
uses them to omit redundant masks and extensions, and to use logical right
shifts for proven nonnegative values.
Word loads omit sign extension when the result uses only the loaded 32 bits.
The compiler also folds masks through extensions and shifts. When one
condition controls both a halfword XOR before a logical shift and the
insertion of disjoint high bits afterward, it combines the two changes
into one conditional XOR after the shift.

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

### C workload examples

Run all eleven self-checking examples in [examples/qbe](../examples/qbe),
or pass the names you want to run. The command uses cproc from `PATH` or
`CPROC` and compiles each program for `simulator.conf`. It checks the
return value with both `simulator.conf` and `one-clock.conf` using the same
binary. The report counts clocks in all outer kernel calls, clocks in
`main` including its self-checks, and total clocks from boot through halt.
Recursive calls are included in their outer call's time.

```sh
just qbe-examples
just qbe-examples quick_sort sha256 goertzel
```

| Example | Workload |
| --- | --- |
| `bubble_sort` | In-place passes over signed integers with duplicate keys |
| `quick_sort` | In-place partitioning and recursive calls |
| `fibonacci` | A loop-carried pair of 64-bit values |
| `mat_mul` | Row-major matrix multiply with signed products and six arguments |
| `crc32` | Reflected IEEE CRC-32 over bytes |
| `rgba_blend` | Integer source-over compositing of straight-alpha `0xRRGGBBAA` pixels |
| `strcpy` | A NUL-terminated string copy to an unaligned address |
| `memmove` | Forward and backward copies over overlapping byte ranges |
| `bresenham` | Integer rasterization of shallow and steep lines |
| `sha256` | SHA-256 rounds, full data blocks, and one- and two-block padding |
| `goertzel` | Single-bin spectral power with a Q14 coefficient |

The SHA-256 example follows the digest and padding specification in
[FIPS 180-4](https://csrc.nist.gov/pubs/fips/180-4/upd1/final).
The Goertzel example uses fixed-point arithmetic for the recurrence
from [Goertzel's original paper](https://courses.cs.washington.edu/courses/cse466/12au/calendar/Goertzel-original.pdf).

`just qbe-coremark` requires cproc on PATH or through the `CPROC` environment
variable. It runs the same kernel driver natively and on MDMA using the
pinned CoreMark list, matrix, and state kernels. One iteration with the
2,000-byte performance configuration must yield CRCs `0xe714`, `0x1fd7`,
and `0x8e3a`.
It reports the ticks for the iteration and for the whole run separately.
The simulator has a 50 million tick limit for the whole run.

`just qbe-coremark-ecp5` runs the same workload on the ECP5 board RTL. It uses
Verilator on PATH or through the `VERILATOR` environment variable. The
testbench runs all clock domains at the same frequency and uses the 256 KiB
on-chip BRAM. It measures CPU clocks between
the iteration entry and a marker before the final CRC checks, then reports
one million divided by that count as the RTL CoreMark/MHz estimate. This is
a single-iteration kernel run.

Each CoreMark recipe uses its matching profile by default. Pass
`--no-schedule` for the baseline or `--schedule PATH` for a custom profile.
In the Python run, the same profile also sets simulator FU timings.
The runner reports image size and code efficiency before timing the run.

`just report-status` rebuilds the QBE backend and builds one Verilator board
model for all workloads. It compiles, assembles, and executes CoreMark and
the C examples `sum_to(10)` and `mix_loop(32, 0x12345678, 0x9e3779b1)`.
Each workload is scheduled for its target. The Python runs use
`src/qbe/profiles/one-clock.conf`, setting every FU's latency and issue
interval to one, including memory, multiplication, and division. The RTL
runs use `src/qbe/profiles/ecp5.conf`.

The final table includes workload clocks, total clocks from boot through
halt, and both CoreMark/MHz scores. CoreMark/MHz uses the timed iteration,
with one simulator tick counted as one CPU clock. Example workload clocks
cover function entry through return to its caller. Every run checks the
result, and CoreMark also checks all three CRCs. The external tool
requirements are the same as for `just qbe-coremark-ecp5`.
