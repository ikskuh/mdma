# Zig toolchain

- Zig is installed as versioned binaries named `zig-<version>`.
- Available versions are `zig-0.11.0`, `zig-0.14.0`, `zig-0.14.1`,
  `zig-0.15.1`, `zig-0.15.2`, `zig-0.16.0`, and
  `zig-0.17.0-dev.2085+5e36170b5`.
- Before running Zig, read `build.zig.zon` and use `minimum_zig_version`.
  If it is absent, ask which Zig version to use.
- Always invoke the versioned binary and mention it in the final response.
- Set `ZIG_GLOBAL_CACHE_DIR` only when the user requests it.

# ECP5 implementation

- Put each functional unit in its own RTL file. Define its ports and
  timing contract so that another implementation can be substituted at
  the same interface.
- Test, synthesize, place, and route every individual component in
  isolation. Expose its inputs and outputs as top-level pins in the
  isolated build so synthesis keeps the full unit live.
- Record synthesis, placement, and routing metrics at every integration
  level, from isolated components through subsystems to the complete design.
- For each changed unit, report routed Fmax, synthesis time, and resource
  usage by type. Explicitly include LUT usage and the number of unique
  physical wire segments used in the final route. State the source of each
  count and include device utilization percentages when totals are available.
  Use matching build settings and counting methods for the baseline and the
  new version. Report the old and new absolute values, then the signed
  absolute and percentage changes. Example format is
  `old 20, new 40, delta +20 (+100%)`. Mark the percentage change as
  undefined when the old value is zero.
- Acceptance requires successful placement and routing of the solution
  and generation of its FPGA bitstream.

# Refactoring and root-cause analysis

- Refactor end to end. Trace the affected behavior from its entry points
  through its implementation and callers, then address the issue across
  the full path.
- This repository is pre-production. Backward compatibility is optional
  across interfaces, formats, and workflows.
- For every issue, consider whether a broader refactor would resolve the
  underlying problem. If it would, explain the scope and tradeoffs and
  clarify the direction with the operator before proceeding.
- Perform a root-cause analysis for every issue. Gather evidence, trace
  the failure to its source, and verify the explanation where possible.
  When the cause remains uncertain, state the evidence-backed hypothesis
  and how to test it.

# Task completion report

After completing every task that changed code, run `just report-status` against the final code
and present its report in the final response. Include the workload and total
clock counts for CoreMark, `sum_to`, and `mix_loop` on the one-clock simulator
and its CoreMark/MHz score. Historical MDMA RTL measurements are in
`docs/ecp5-legacy-stats.md`.

Use `CPROC` when the compiler needs an explicit path. If the command fails, report the
failure and its cause. Present fresh measurements from the current task.

