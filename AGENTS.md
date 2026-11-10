# Zig toolchain

- Zig is installed as versioned binaries named `zig-<version>`.
- Available versions are `zig-0.11.0`, `zig-0.14.0`, `zig-0.14.1`,
  `zig-0.15.1`, `zig-0.15.2`, `zig-0.16.0`, and
  `zig-0.17.0-dev.2085+5e36170b5`.
- Before running Zig, read `build.zig.zon` and use `minimum_zig_version`.
  If it is absent, ask which Zig version to use.
- Always invoke the versioned binary and mention it in the final response.
- Set `ZIG_GLOBAL_CACHE_DIR` only when the user requests it.

# Task completion report

After completing every task that changed code, run `just report-status` against the final code
and present its report in the final response. Include the workload and total
clock counts for CoreMark, `sum_to`, and `mix_loop` on the one-clock simulator
and ECP5 RTL, together with both CoreMark/MHz scores.

Use the `CPROC`, `VERILATOR`, and `VERILATOR_ROOT` environment variables when
the external tools need explicit paths. If the command fails, report the
failure and its cause. Present fresh measurements from the current task.

