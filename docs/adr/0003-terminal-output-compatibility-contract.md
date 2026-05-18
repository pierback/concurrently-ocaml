# ADR 0003: Terminal Output Compatibility Contract

## Status

Accepted.

## Context

The project target is not only feature parity with npm `concurrently`; it must
also feel as fast and ergonomic in the terminal. For this tool, terminal output
is the main product surface. Prefixes, spacing, grouping, colors, raw output,
lifecycle messages, close messages, timing output, and stdout/stderr routing
shape whether users can replace npm `concurrently` without relearning their
workflow.

The OCaml implementation should be faster through native startup, bounded
process supervision, and efficient output streaming, but speed cannot come at
the cost of visibly worse terminal behavior. Formatter differences that look
minor in unit tests can be user-visible regressions in interactive terminals,
CI logs, and npm script output.

## Decision

Treat terminal output compatibility as a product contract, not polish.

`Output_formatter` must match npm `concurrently` formatting byte-for-byte for
deterministic CLI cases, including stdout/stderr routing, prefixes, prefix
padding, spacing, grouping, raw mode, hidden output, lifecycle messages,
cancellation messages, restart messages, timing tables, and color behavior when
colors are deterministic.

The pinned compatibility harness against npm `concurrently` is the authority
for deterministic formatter behavior. New formatter features should add or
extend compatibility cases that compare the local native binary with pinned npm
`concurrently` on stdout, stderr, exit status, signal, and output ordering.

Intentional differences must be recorded in the feature parity plan as either
incomplete work or an explicitly justified non-goal. Undocumented formatter
differences are bugs.

Keep the formatter fast:

- Do not buffer unbounded command output.
- Keep line/block buffering scoped to the behavior that requires it, such as
  grouped output or npm-compatible timing blocks.
- Keep output event handling explicit and bounded.
- Avoid adding compatibility layers or alternate formatting modes for legacy
  behavior; use hard cutovers to the npm-compatible behavior.

## Consequences

- Formatter work must prioritize visible npm parity before broader feature
  expansion.
- Unit tests can cover pure formatting invariants, but byte-level CLI
  compatibility tests are required for user-visible terminal behavior.
- Performance work must preserve terminal fidelity. If a faster implementation
  changes deterministic output shape, the output shape wins unless the feature
  parity plan records a deliberate non-goal.
- The Runner should continue emitting structured facts. `Output_formatter`
  remains the module responsible for translating those facts into terminal
  bytes.
- Raw, grouped, timing, and color behavior are part of the compatibility
  contract and should not be treated as optional display polish.

## References

- Feature parity plan: `docs/architecture/feature-parity-plan.md`
- npm concurrently logger: `open-cli-tools/concurrently/lib/logger.ts`
- npm concurrently timings flow controller:
  `open-cli-tools/concurrently/lib/flow-control/log-timings.ts`
