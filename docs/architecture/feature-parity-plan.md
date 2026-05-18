# Feature Parity Architecture Plan

## Target

Build `concurrently-ocaml` as a feature-complete OCaml implementation of npm
`concurrently` v9.2.1, with a hard-cutover OCaml 5.4.1 + Dune 3.23 + Eio
architecture and reproducible native npm distribution.

The target is not a thin CLI wrapper. The library should own the core run model,
and the executable should only parse CLI input, call the library, and translate
the final run result to a process exit code.

The core domain model must stay OS-neutral. Process supervision is a backend
concern: Unix-like runners and Windows runners should share the same
`Command`/`Run_policy`/`Run_spec` model but use platform-specific spawn,
signal, process-tree teardown, and pipe implementations.

## Current State

- `bin/main.ml` now parses CLI input with Cmdliner into validated
  `Cli_config.t`, creates an `Output_formatter.t`, calls `Runner.run`, prints
  formatter output, and maps the final run result to an exit code.
- `lib/runner.ml` owns OS-neutral orchestration: bounded `max_processes`,
  retries, sibling cancellation decisions, output-event reading, close-event
  collection, and `Run_result` construction.
- `lib/runner_backend.ml` defines the backend contract. `lib/posix_runner_backend.ml`
  owns POSIX shell selection, Eio POSIX process spawning, stdout/stderr pipe
  creation, process-group signalling, process identity exposure, and POSIX
  close-status mapping.
- The blocking `Unix.open_process_full` / `Unix.fork` / `Unix.waitpid`
  orchestration has been removed from the executable.
- Output now flows through structured `Output_event.t` callbacks as lines are
  read from child pipes. `lib/output_formatter.ml` owns prefix modes, prefix
  padding, command-prefix truncation, timestamp prefixes, ANSI color rendering,
  spacious blocks, timings output, and command-level buffering for the
  currently exposed flags.
- Kill-others now starts each POSIX command in its own process group and signals
  the group so shell children are cancelled with their parent shell.
- The npm launcher prefers the local Dune binary inside a source checkout and
  prefers optional native platform packages from installed package roots.
- GitHub Actions now includes a native package matrix for Linux x64/arm64 and
  macOS x64/arm64. Windows packaging is deliberately withheld until a
  Windows-native runner backend exists.

## Deepening Opportunities

1. Runner module

   Files: `bin/main.ml`, future `lib/runner.ml`, `lib/runner.mli`.

   Problem: command lifecycle behavior is mixed with CLI parsing and formatting.
   The module is shallow because callers must understand Unix spawning, output
   buffering, timing, exit mapping, and kill rules at once.

   Solution: create a deep Runner module that accepts a validated run spec and
   emits output events plus close events. Its implementation owns Eio fibers,
   process handles, bounded parallelism, cancellation, restart attempts, signal
   delivery, and teardown.

   Benefits: lifecycle bugs gain locality, tests target the interface, and the
   CLI gains leverage without knowing process internals.

2. Run policy module

   Files: `bin/main.ml`, future `lib/run_policy.ml`, `lib/run_policy.mli`.

   Problem: kill flags, success condition, restart limits, max-processes, and
   teardown semantics will become branch-heavy if added directly to the CLI.

   Solution: model run policy as immutable data validated at construction.
   Reject impossible states early, such as zero `max_processes`, negative restart
   counts, or kill policies with invalid signals.

   Benefits: invalid states become loud, policy tests cover npm parity rules,
   and the Runner can remain a predictable state machine.

3. Output formatter module

   Files: `bin/main.ml`, future `lib/output_formatter.ml`,
   `lib/output_formatter.mli`.

   Problem: formatting depends on mutable globals and buffered lines. It cannot
   support raw output, hidden commands, prefix padding, timestamp templates,
   partial lines, or color policy cleanly.

   Solution: format output events as they arrive. Keep prefix rendering, color
   selection, timestamp formatting, and raw/hidden behavior behind one seam.

   Benefits: streaming output becomes testable through events and golden output
   tests, while the Runner only emits structured facts.

4. CLI config module

   Files: `bin/main.ml`, future `lib/cli_config.ml`,
   `lib/cli_config.mli`.

   Problem: global refs let parsing and execution share mutable state. That
   hides invariants, such as "command list is non-empty" and "names match command
   count."

   Solution: use Cmdliner to parse all CLI inputs into one immutable config,
   then convert it to validated command specs and run policy.

   Benefits: the executable becomes small, CLI errors become deterministic, and
   command/run policy tests no longer need to execute processes.

5. Input router module

   Files: `lib/input_router.ml`, `lib/input_router.mli`,
   `lib/runner.ml`, `lib/runner_backend.mli`,
   `lib/posix_runner_backend.ml`.

   Problem: npm `concurrently` supports input handling and a default input
   target. Adding that directly to the Runner would mix terminal concerns with
   process lifecycle.

   Solution: parse npm-compatible `index:` and `name:` prefixes in the
   OS-neutral input router, then route resolved payloads to backend-owned stdin
   operations through the Runner.

   Benefits: terminal behavior has locality, and command supervision remains
   independent from stdin parsing.

## Feature Matrix

| Feature | Target module | Status |
| --- | --- | --- |
| Multiple commands | Runner | Implemented through `Runner.run` |
| Real concurrent execution | Runner | Implemented for one attempt per command |
| Command names | CLI config, Output formatter | Implemented for `-n`/`--names` plus `--name-separator`; labels preserve spaces like npm |
| Prefix modes: index, pid, time, command, name, none, template | Output formatter | Implemented for formatter output; PID comes from backend process identity on output events |
| Prefix colors and auto colors | CLI config, Output formatter | Partial `--prefix-colors` support for basic colors, backgrounds, modifiers, `auto`, `reset`, and `#RRGGBB` foregrounds |
| Prefix length and padding | Output formatter | Implemented via `--prefix-length` and `--pad-prefix` |
| Raw output | CLI config, Output formatter | Partial global `--raw` support |
| Hide selected command output | CLI config, Output formatter | Partial `--hide` by index/name |
| Cwd per run and per command | CLI config, Runner | Missing |
| Env per command | CLI config, Runner | Partial `Command.env` merge in `Runner`; CLI flags missing |
| Kill others on success/failure | Run policy, Runner | Implemented for POSIX process groups |
| Signal choice and kill timeout | Run policy, Runner | Partial common signal support through `--kill-signal` and npm alias `--ks`; `--kill-timeout` force-kills still-running POSIX process groups with `SIGKILL` |
| Max running processes | Run policy, Runner | Implemented via `-m`/`--max-processes` for exact counts; percent-of-CPU values are missing |
| Success condition: all, first, last, command selectors | Run policy, Runner | Implemented via `--success` |
| Restart tries and delay | Run policy, Runner | Implemented for finite tries via `--restart-tries` and millisecond `--restart-after` |
| Exponential restart backoff | Run policy, Runner | Implemented for finite tries via `--restart-after exponential` |
| Input forwarding | Input router, Runner | Implemented for POSIX through `-i`/`--handle-input`; stdin write races are isolated by the backend interface |
| Default input target | Input router | Implemented through `--default-input-target` by index or name |
| Teardown commands | CLI config, Run policy, Runner | Implemented for sequential cleanup commands with raw output and exit-code isolation |
| Timings output and close-event timings | Runner, Output formatter | Partial: close-event timings and npm `--timings` output are implemented |
| Programmatic library entrypoint | Library root | Partial `Runner.run` API with explicit backend |

## Implementation Slices

1. Toolchain hard cutover

   Update package metadata to OCaml 5.4.1, Dune 3.23, Eio 1.3, Cmdliner 2.x,
   and ANSITerminal. Remove metadata placeholders and make `dune build` the
   source of truth.

   Status: complete in the current workspace metadata. Build verification passes
   in an isolated OCaml 5.4.1 opam switch.

2. Domain library skeleton

   Add `Command`, `Run_policy`, `Run_spec`, `Output_event`, `Close_event`, and
   `Run_result` types in `lib/`. Keep constructors narrow and assert invariants
   at creation.

   Status: complete in the current workspace. The modules now expose validated
   constructors and focused tests for command, policy, event, close-event, spec,
   and result invariants.

3. CLI config hard cutover

   Replace global `Arg` refs with Cmdliner parsing into immutable config. Keep
   the executable thin.

   Status: complete for the currently exposed flags. `bin/main.ml` now parses
   through Cmdliner and converts arguments into validated `Cli_config.t`,
   `Command.t`, `Run_spec.t`, and `Run_policy.t` values before execution. The
   executable now delegates process supervision to `Runner` and formatting to
   `Output_formatter`.

4. Eio Runner hard cutover

   Replace the blocking Unix runner with an Eio process supervisor. Implement
   true concurrent execution, bounded `max_processes`, real-time stdout/stderr
   events, and close-event collection.

   Status: partially complete. The executable now calls `Runner.run` with
   `Posix_runner_backend.backend`, and the blocking Unix orchestration has been
   deleted. The Runner executes commands concurrently with Eio fibers, bounds
   fan-out with `Run_policy.max_processes`, emits structured output events,
   collects close events, and constructs `Run_result.t`. Restart attempts and
   retry delays are implemented without holding process slots; retry waits stop
   early when cancellation closes the command. Teardown commands run after the
   main run drains, emit raw output, and do not alter the main exit code.
   Remaining Runner work: cwd CLI wiring and stronger process-level parity
   tests.

5. Output formatter parity

   Implement prefix modes, raw mode, color policy, prefix length, padding,
   timestamp format, and hidden output. Test formatter behavior without running
   processes.

   Status: partially complete. `lib/output_formatter.ml` now owns labels,
   prefix modes, command-prefix truncation, prefix padding, timestamp prefixes,
   explicit prefix colors, ANSI color rendering, no-color mode, spacious
   output, timings output through npm's `--timings` flag, global raw output, hidden command output,
   command-level buffering, PID prefixes and `{pid}` template placeholders from
   backend process identity, and deterministic no-color unit tests. Remaining
   formatter work: per-command raw flags from structured command input, full
   chalk compatibility, and golden CLI compatibility tests.

6. Run policy parity

   Implement kill-others-on success/failure, success condition, restart tries,
   restart delay, exponential restart, signal propagation, and no-start-after
   cancellation semantics.

   Status: partially complete. `--success` now supports `all`, `first`, `last`,
   `command-{index}`, `command-{name}`, and `!command-{index/name}` through the
   OS-neutral `Run_policy` module. `--restart-tries` and `--restart-after` now
   support finite retry counts, fixed millisecond delays, and npm-compatible
   exponential delay timing (`2^N` seconds for retry index `N`). Remaining run
   policy work: npm's negative infinite restart count and
   no-start-after cancellation semantics.

7. Input and teardown

   Implement input routing, default input target, stdin shutdown behavior, and
   teardown commands.

   Status: partially complete. `--teardown` now accepts repeated cleanup
   commands through `Cli_config`, stores validated raw cleanup commands on
   `Run_policy`, and executes them through the same `Runner_backend` seam after
   the main command run drains. Cleanup output is raw and cleanup exit status is
   deliberately excluded from `Run_result` success calculation. `-i`/`--handle-input`
   and `--default-input-target` now route stdin lines through `Input_router` to
   command stdin, including npm-compatible `index:` and `name:` prefixes.
   Remaining work: broader compatibility tests against npm `concurrently`.

8. Compatibility test suite

   Add process-level tests that compare key CLI behavior against npm
   `concurrently` v9.2.1 where practical, plus unit tests for policy and
   formatting.

9. Npm binary distribution

   Decide and implement the Node-facing package contract. Feature-complete npm
   parity requires ready-to-run native binaries or platform-specific binary
   packages so `conc` works immediately after npm install.

   Status: partially complete. The root package now declares optional platform
   packages for Linux and macOS targets, and the launcher resolves the matching
   native package before falling back to a local development build. GitHub
   Actions builds platform packages and publishes them on version tags. Windows
   packaging is withheld until a Windows backend exists. Remaining distribution
   work: add checksums or SLSA/provenance policy beyond npm provenance, add
   platform package smoke installs, decide whether Linux musl/static builds are
   required, and implement then package Windows runner behavior.

10. Platform backend split

   Introduce a `Runner_backend` interface so the OS-neutral `Runner` can
   orchestrate policy, retries, and events while platform backends own spawn,
   signal, process-tree teardown, pipe capture, and platform error mapping.

   Status: partial implementation complete. `Runner.run` now takes an explicit
   `Runner_backend.t`, and the CLI/test harness selects
   `Posix_runner_backend.backend`. The POSIX backend owns `/bin/sh`, Eio POSIX
   spawning, process-group signalling, pipe creation, process identity, and
   process close-status mapping. Remaining backend work: add a Windows backend
   with native shell and process-tree semantics, move stdin/input routing
   through the same seam, and add backend conformance tests.

## Test Strategy

- Unit tests: validation, policy decisions, prefix rendering, timestamp
  rendering, success-condition calculation, restart backoff.
- Integration tests: concurrent timing, streaming output interleaving, stderr,
  spawn failure, signal handling, kill-others, max-processes queue behavior,
  restart exhaustion, teardown order.
- CLI tests: argument parsing, help text, aliases, error messages, exit codes.
- Performance checks: startup overhead, N short commands, long-running streaming
  commands, bounded memory with many output lines.

## Performance Sketch

The hot path is command output streaming. It should avoid buffering whole stdout
or stderr in memory. Output should be processed as bounded byte chunks or lines,
formatted once, and written once.

The control path is process lifecycle. It should keep one bounded queue of
pending commands, one bounded set of running commands, and one close-event list
whose maximum length is derived from `command_count * (restart_tries + 1)`.

`max_processes` must bound process fan-out. Restart policy must bound attempts.
Input routing must not accumulate unbounded pending writes to a dead command.

## Open Questions

- Should the public library expose an OCaml API only, or also preserve a
  Node-facing package contract through the existing npm package?
- Should command expansion include npm/yarn/pnpm/bun/node/deno shortcut behavior
  in the first parity pass, or after the Runner is stable?
- Which Windows process-tree and shell strategy should the future backend use?
