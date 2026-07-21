# Feature Parity Map

This document describes the implementation that exists today. The exact npm
version, source revision, integrity hash, reference-suite counts, and parity
rules live in [upstream-parity.md](upstream-parity.md).

## Product Boundary

`concurrently-ocaml` is a native OCaml implementation of the public
`concurrently@10.0.0` CLI and its commonly used JavaScript facade. The native
implementation owns process supervision; it does not install or execute the
upstream package at runtime.

The CLI is the primary compatibility surface. A public JavaScript extension is
only considered compatible when its behavior is tested, not merely because an
export with the same name exists. Unsupported extension points must fail
explicitly instead of silently doing nothing.

## Architecture

The code follows one path from input to completion:

1. `Cli_argv` merges supported `CONCURRENTLY_*` defaults with explicit argv.
2. `Cli_config` validates commands, formatting options, and lifecycle policy.
3. `Run_api` converts CLI or structured API input into OS-neutral command and
   policy values.
4. `Runner` owns scheduling, restart decisions, cancellation, input routing,
   output events, teardown, and the final `Run_result`.
5. A platform backend owns spawning, pipes, process identity, signals, and
   process-tree termination.
6. `Output_formatter` converts structured events into the public terminal
   stream.

The executable only connects these modules and projects `Run_result` to an exit
code. POSIX and Windows implementations share the same domain model. The
JavaScript facade translates its supported object API into the same native run
configuration, while its spawn-backed compatibility path supplies observable
`Command` objects.

## Implemented Feature Surface

### Command selection and configuration

- concurrent execution with exact or percentage `--max-processes` limits;
- names, index fallback, command/name/index/time/none/template prefixes;
- named, bright, background, modifier, hexadecimal, automatic, and reset
  prefix colors;
- prefix truncation and padding with JavaScript-compatible numeric coercion;
- per-run and structured-API per-command cwd and environment values;
- npm, yarn, pnpm, bun, node, and deno shortcuts;
- package-script wildcards and omission filters;
- passthrough `{1}`, `{@}`, and `{*}` argument expansion;
- selectors by command index or name.

### Output and terminal behavior

- streaming stdout and stderr with partial-line and CRLF handling;
- raw, hidden, grouped, and spacious output;
- lifecycle, cancellation, and completion messages;
- command, index, name, PID, time, and template labels;
- timing summaries and close-event timing metadata;
- deterministic help, version, validation, and unknown-option behavior;
- input forwarding and default input targets.

### Lifecycle policy

- success conditions `all`, `first`, `last`, and command selectors;
- kill-others on success or failure;
- configured kill signals, signal forwarding, timeout, and forced termination;
- finite and infinite restart limits with fixed or exponential delays;
- bounded scheduling across restarted commands;
- sequential teardown commands whose failures do not replace the run result;
- POSIX process-group cleanup and Windows job-object cleanup.

### Distribution and APIs

- `concurrently` and `conc` npm binaries;
- packed CommonJS, ESM, and TypeScript entrypoints;
- platform-specific optional native packages with checksum verification;
- structured OCaml `Run_api` input;
- high-level JavaScript `concurrently()` execution with command observables;
- tested JavaScript controllers for input, kill policies, output, errors, exit
  logging, and timings.

## Known JavaScript Extension Gaps

The JavaScript facade is deliberately narrower than upstream internals:

- low-level `createConcurrently()` does not yet provide the upstream core
  scheduler contract;
- standalone `Logger` color rendering is not yet behaviorally compatible;
- signal and restart controllers are not composable over the current public
  command-close stream and therefore fail explicitly;
- OCaml IPC support exposes process metadata but does not reproduce the full
  Node child-process IPC channel.

These are open parity work, not accepted divergences. Their upstream specs are
part of the final coverage inventory described in
[upstream-parity.md](upstream-parity.md).

## Verification

Run the maintained local gate:

```sh
npm run test:parity
```

It builds the installable OCaml targets, runs native unit and end-to-end tests,
audits the packed npm and TypeScript surface, compares deterministic CLI and
JavaScript behavior with the integrity-pinned upstream package, and installs
the packed host package in a clean project.

Platform packaging workflows repeat the install smoke for Linux GNU, Linux
musl, macOS, and Windows. Windows-specific command quoting, signals, pipes, and
job-object cleanup are exercised in Windows CI because they cannot be executed
on a POSIX development host.

The reference suite itself contains 630 unit tests and 4 smoke tests. It is the
final parity inventory, but most tests import upstream TypeScript internals and
must be adapted before they prove behavior in this implementation. See
[upstream-parity.md](upstream-parity.md) for the exact distinction.

## Performance Invariants

- child output is streamed in bounded chunks rather than accumulated globally;
- formatter work is proportional to emitted output;
- process concurrency is bounded by policy;
- cancellation terminates command trees, not only their shell parents;
- the native CLI has no runtime dependency on upstream JavaScript internals.

Repeatable comparative workloads and the latest recorded sample live in
[performance-evidence.md](performance-evidence.md). Timing is treated as
evidence rather than a host-dependent pass/fail threshold.
