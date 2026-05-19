# Feature Parity Architecture Plan

## Target

Build `concurrently-ocaml` as a feature-complete native OCaml CLI replacement
for npm `concurrently`/`conc` v9.2.1 in package scripts, with a hard-cutover
OCaml 5.4.1 + Dune 3.23 + Eio architecture and reproducible native npm
distribution.

Speed and terminal ergonomics are primary product requirements. The native
implementation should preserve the OCaml advantage with fast startup,
low-overhead process supervision, bounded memory, efficient output streaming,
and formatter work proportional to emitted output. The terminal surface is part
of compatibility: familiar flags, byte-compatible deterministic output,
predictable validation errors, raw/grouped/prefixed formatting, lifecycle
messages, timing tables, and npm install/run behavior all belong in the parity
contract.

The target is not a thin CLI wrapper. The library should own the core run model,
and the executable should only parse CLI input, call the library, and translate
the final run result to a process exit code.

The JavaScript programmatic API from npm `concurrently` is an explicit
non-goal. This package should not ship CommonJS or ESM import entrypoints,
command observables, Node IPC shims, or custom JavaScript spawn/kill hooks.
JavaScript is limited to npm install, launcher, packaging, and compatibility
test glue.

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
  internal block formatting, timings output, and command-level buffering for
  the currently exposed flags.
- Kill-others now starts each POSIX command in its own process group and signals
  the group so shell children are cancelled with their parent shell.
- The npm launcher prefers the local Dune binary inside a source checkout and
  prefers optional native platform packages from installed package roots. The
  root npm package exposes npm-compatible `concurrently` and `conc` binary
  aliases plus the project-specific `concml` alias.
- GitHub Actions now includes a native package matrix for Linux x64/arm64 and
  macOS x64/arm64. Each native package job now packs the platform package and
  root package into a clean npm project, verifies that the root tarball did not
  leak OCaml source/build/test files, and runs `conc`/`concurrently` from that
  install. Windows packaging is deliberately withheld until a Windows-native
  runner backend exists.

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
   Reject impossible states early, such as zero `max_processes`, invalid restart
   delay bounds, or kill policies with invalid signals. Represent finite and
   infinite restart limits explicitly so retry-forever behavior does not leak an
   integer sentinel into the Runner.

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
   hides invariants, such as "command list is non-empty", "command names may be
   shorter than the command list", and "shortcut-generated names participate in
   selectors."

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
| Command names | CLI config, Output formatter | Implemented for `-n`/`--names` plus `--name-separator`; labels preserve spaces, missing names fall back to indexes by default, extra names are ignored, deprecated separator warnings match npm, and empty separators split names into single-character labels like npm |
| Prefix modes: index, pid, time, command, name, none, template | Output formatter | Implemented for formatter output; PID comes from backend process identity on output events |
| Prefix colors and auto colors | CLI config, Output formatter | Implemented for pinned npm-published reset defaults, named colors, modifiers, bright colors, backgrounds, `auto`, `reset`, invalid-color fallback, function-style fallback, and short/full `#RGB`/`#RRGGBB` foregrounds |
| Prefix length and padding | Output formatter | Implemented via `--prefix-length` and `--pad-prefix`, including npm-compatible default fallback, compact numeric `-lN` values, and JavaScript slicing semantics for zero, invalid, finite fractional, negative, and `Infinity` prefix lengths |
| Raw output | CLI config, Run API, Output formatter | Global `--raw` support plus per-command raw mode through structured `Run_api` inputs |
| Hide selected command output | CLI config, Output formatter | Implemented for `--hide` by index, name, and comma-separated selectors |
| Grouped output | CLI config, Output formatter | Implemented via `-g`/`--group`; non-raw command output is emitted on stdout and released in command index order |
| Command close notifications | Runner, Output formatter, Run result | Implemented for default formatted output, grouped output, signal labels, cancellation status lines, raw/hidden suppression, and `-k` killed-sibling exit calculation like npm |
| Cwd per run and per command | Run API, Runner | CLI `--cwd` is not exposed by pinned `concurrently@9.2.1`; structured OCaml `Run_api` commands can still provide cwd values before they reach the Runner |
| Env per command | Run API, Runner | Structured `Run_api` commands support per-command env merged by `Runner`; CLI env flags are not an npm surface |
| Kill others on success/failure | Run policy, Runner | Implemented for POSIX process groups |
| Signal choice and kill timeout | Run policy, Runner | Implemented for OCaml/POSIX-supported signal names and aliases through `--kill-signal`, npm alias `--ks`, and `CONCURRENTLY_KILL_SIGNAL`/`CONCURRENTLY_KS`, including deterministic `SIGINT` and `SIGUSR1` parity; `--kill-timeout` accepts npm-style numeric coercion for invalid, sub-millisecond fractional, fractional, and negative values, emits npm-compatible Node timer warning text for negative values when used, emits force-kill status after the timeout window, and force-kills still-running POSIX process groups with `SIGKILL` |
| Max running processes | CLI config, Run policy, Runner | Implemented via `-m`/`--max-processes` for exact counts, compact numeric `-mN` values, and percent-of-detected-CPU values |
| Passthrough arguments | CLI config, Argument expander | Implemented via `-P`/`--passthrough-arguments` for `{1}`, `{@}`, and `{*}` placeholders |
| Command shortcuts and script wildcards | CLI config, Script catalog | Implemented shortcut expansion for `npm:`, `yarn:`, `pnpm:`, `bun:`, `node:`, and `deno:` with npm-compatible default names, package-script wildcards, verbatim wildcard command construction, omission filters against full script names, and deno task/package-script lookup |
| Success condition: all, first, last, command selectors | Run policy, Runner | Implemented via `--success`, including npm-compatible fallback where unmatched success values behave like `all` |
| Restart tries and delay | Run policy, Runner | Implemented for finite tries, fractional/invalid npm completion-status projection, and npm-compatible negative/`Infinity` retry-forever counts via `--restart-tries`, plus npm-compatible `--restart-after` coercion for exponential, blank-as-zero, numeric, fractional, negative, unused invalid values, and invalid-delay warning text when retries use the timer |
| Exponential restart backoff | Run policy, Runner | Implemented via `--restart-after exponential`; finite retry counts are overflow-validated up front, while retry-forever delays saturate instead of asserting on unreachable high attempts |
| Input forwarding | Input router, Runner | Implemented for POSIX through `-i`/`--handle-input`; stdin write races are isolated by the backend interface |
| Default input target | Input router | Implemented through `--default-input-target` by index or name, including npm-compatible runtime handling for unresolved default targets and empty-target coercion to command `0` |
| Teardown commands | CLI config, Run policy, Runner | Implemented for sequential cleanup commands, empty teardown shell commands, raw output, and exit-code isolation |
| `CONCURRENTLY_*` environment defaults and boolean coercion | CLI env options, CLI argv, CLI config | Implemented for pinned npm CLI flags and aliases through argv normalization; explicit CLI arguments override env defaults, and yargs-style boolean `--flag=true/false`, non-true inline false, `--no-flag` negation, known short boolean groups like `-kg`/`-rg`, and mixed unknown/known short groups like `-xg`/`-xr`/`-rx` are supported |
| Timings output and close-event timings | Runner, Output formatter | Partial: npm-style lifecycle timing messages and summary tables are implemented for deterministic success, failure, restart, hidden, raw, named, grouped, custom timestamp, and kill-on-fail cases |
| Help and version flags | CLI argv, CLI config, npm distribution | Implemented for `--version`, `-v`, `-V`, `--help`, `-h`, yargs-style built-in aliases before separate option values, and no-command default help on stderr after npm-compatible unknown-option normalization; deterministic help output is pinned byte-for-byte against npm `concurrently@9.2.1`, and npm install smoke verifies matching `concurrently`/`conc` help aliases |
| OCaml run API | Run API, Runner | Implemented for structured OCaml callers; not shipped as a JavaScript package API |

## Compatibility Evidence And Divergence Ledger

Pinned compatibility evidence lives in `scripts/ci/compat-concurrently.js`. The
harness runs the local native binary and npm `concurrently@9.2.1` with the same
CLI arguments, then compares exit status, signal, stdout, and stderr
byte-for-byte for deterministic cases. Each case names the upstream behavior
spec or smoke area it mirrors.

Currently mirrored deterministic behavior:

- `src/flow-control/log-exit.spec.ts`: command close notifications for success,
  failure, and signals.
- `bin/concurrently.spec.ts`: `--version`, `-v`, and `-V` terminate cleanly
  with a package-version-shaped stdout line; `--help` and `-h` produce
  byte-compatible yargs help text, including built-in alias parsing before
  separate option values; no-command invocations and unknown options that
  consume the only command also produce byte-compatible default help on stderr
  with exit status 0.
- Published `dist/src/completion-listener.js`: unmatched `--success` values and
  empty command selectors fall back to the default all-command success
  condition, including failed-command exit projection.
- `src/logger.spec.ts` and `bin/concurrently.spec.ts`: raw/hidden suppression,
  formatted child stderr-to-stdout routing, grouped stderr-to-stdout routing,
  name prefixes, deprecated name separator warnings, empty separator name splitting, command prefixes,
  npm-compatible prefix-length coercion and truncation, template prefixes, PID
  prefixes, no-prefix mode, and prefix padding.
- Published `dist/bin/concurrently.js` and `docs/cli/configuration.md`:
  `CONCURRENTLY_*` environment defaults for deterministic flags and aliases,
  including explicit CLI boolean false overriding env true, non-true inline
  boolean false coercion, and `--no-flag` negation with last-value-wins
  behavior, known short boolean alias groups such as `-kg` and `-rg`, mixed
  unknown/known short-option groups such as `-xg`, `-xr`, and `-rx`, and compact
  numeric short values such as `-m1` and `-l2`, and short inline string values
  such as `-p=raw` and `-n=api`, while compact string forms such as `-pcommand`
  and `-napi,web` do not bind string option values; compact short CLI values
  override `CONCURRENTLY_M`/`CONCURRENTLY_L` defaults, full-name
  `CONCURRENTLY_MAX_PROCESSES` scheduling defaults, and input-routing defaults
  from `CONCURRENTLY_HANDLE_INPUT` plus `CONCURRENTLY_DEFAULT_INPUT_TARGET`;
  yargs-style missing separate option values before boolean flags are dropped
  before command binding.
- Published `dist/src/logger.js`/`dist/src/defaults.js` color behavior:
  byte-compatible ANSI output for default reset-colored prefixes, `red.bold`,
  `bgRed.white.bold`, `bgBlueBright.white`, `gray.dim`, `auto`, `hidden`,
  short/full truecolor hex prefixes, invalid-color fallback, and
  published-package function-style fallback for `rgb(...)` and `ansi256(...)`
  values under deterministic `FORCE_COLOR` settings, including full-name
  `CONCURRENTLY_PREFIX_COLORS` environment defaults.
- `src/command-parser/expand-arguments.spec.ts` and `bin/concurrently.spec.ts`:
  passthrough placeholder expansion and disabled passthrough behavior.
- Published `dist/src/command-parser/expand-shortcut.js`: simple command
  shortcut expansion (`npm:<script>`, `yarn:<script>`, `pnpm:<script>`,
  `bun:<script>`, `node:<script>`, `deno:<script>`), generated default names,
  explicit name override behavior, mixed shortcut/literal default prefixes, and
  passthrough expansion before shortcut parsing.
- Published `dist/src/command-parser/expand-wildcard.js`: package script
  wildcard expansion for `npm:<glob>`, `yarn:<glob>`, `pnpm:<glob>`,
  `bun:<glob>`, and `node:<glob>`, Deno task wildcard expansion for
  `deno:<glob>`, wildcard-generated names, explicit name prefixes, verbatim
  expansion of spaced script names, and omission filters against full script
  names for deterministic package-script cases, plus no-match wildcard
  expansion as a clean no-output no-op.
- `bin/concurrently.spec.ts`, published `dist/bin/concurrently.js`, and
  `dist/src/flow-control/restart-process.js`: finite `--restart-tries` restart
  notifications, negative `--restart-tries` retry-forever behavior until a
  later attempt succeeds, `Infinity` retry-forever behavior, fractional and
  invalid `--restart-tries` completion status projection, and deterministic
  `--restart-after` coercion for unused invalid values, blank-as-zero values,
  negative/fractional retry delays, and invalid-delay timer warning text in
  formatted and raw modes.
- `bin/concurrently.spec.ts` and `src/flow-control/teardown.spec.ts`:
  teardown status messages, empty teardown commands, raw teardown output, and
  raw-mode suppression of global teardown status messages.
- `src/flow-control/kill-others.spec.ts` and `bin/concurrently.spec.ts`:
  `--kill-others`, `--kill-others-on-fail`, cancellation status messages, signal
  close output, success projection, configured `SIGINT` and `SIGUSR1` kill
  signals, and max-process queued-command suppression after success or failure
  cancellation.
- Published `dist/bin/concurrently.js` and `dist/src/flow-control/kill-others.js`:
  `--ks` alias handling and full-name/alias
  `CONCURRENTLY_KILL_SIGNAL`/`CONCURRENTLY_KS` environment defaults for
  deterministic sibling cancellation, plus lazy signal resolution where an
  unsupported `--kill-signal` value is accepted when no sibling signal is ever
  sent, and yargs-style empty `--kill-signal ''` values fall back to the
  default `SIGTERM` signal.
- Published `dist/src/flow-control/kill-others.js` and
  `dist/bin/concurrently.js`: deterministic `--kill-timeout` numeric coercion
  for sub-millisecond fractional and fractional escalation delays, invalid
  unused values, and negative-delay timer warning text in formatted and raw
  modes.
- `src/concurrently.spec.ts`: deterministic `maxProcesses` command-start
  serialization, including the documented rule that queued commands start only
  after a running command has exhausted its restart attempts, and that
  never-started queued commands do not print synthetic killed output after a
  cancellation condition fires.
- `src/flow-control/input-handler.spec.ts` and `bin/concurrently.spec.ts`:
  `--handle-input`, explicit index and command-name routing,
  `--default-input-target` behavior with bounded delayed stdin writes, and
  runtime logging for unresolved default input targets, including empty-target
  coercion to command `0`.
- `lib/flow-control/log-timings.ts` and `lib/flow-control/log-timings.spec.ts`:
  `--timings` start/stop lifecycle messages and final summary tables for
  success, failure, named commands, hidden commands, raw-mode suppression, and
  grouped sorted output, finite restart attempts, custom `--timestamp-format`,
  and deterministic kill-on-fail signalling, with timestamps and measured
  durations normalized because they are inherently runtime-dependent.

Known divergences tracked as incomplete work:

| Area | Upstream behavior | Current status |
| --- | --- | --- |
| Timing table row order for runtime-dependent signal durations | npm sorts the timing table by measured duration. When one command is killed after another exits, relative durations can legitimately differ by runtime and platform. | Deterministic kill-on-fail signal timing matches npm under normalized timestamps/durations. Success-triggered kill timing is not pinned byte-for-byte because duration-sorted row order depends on process scheduling and signal latency. |
| SIGHUP shell job-control diagnostics | For shell commands such as `trap 'exit 129' HUP; sleep 1`, npm's process-tree kill path can surface an extra shell diagnostic like `Hangup: 1` before the command close notification. | The native POSIX backend signals the command process group directly, so the deterministic close status matches but that shell-emitted diagnostic is not reproduced. This remains tracked as process-tree parity work, not formatter output to fake. |
| Unsupported kill-signal values when used | Upstream forwards the exact `--kill-signal` string to Node/tree-kill. Bare aliases such as `TERM`/`HUP`, and unsupported names such as `SIGFOO`, print a partial shutdown log and then throw Node's `ERR_UNKNOWN_SIGNAL` stack when used. | The native CLI accepts unused signal values like npm, supports deterministic OCaml/POSIX `SIG*` values when cancellation actually sends a signal, and returns a typed native error instead of reproducing Node's stack trace for unsupported values that are used. |
| JavaScript programmatic API | Upstream `concurrently()` can be imported from JavaScript. | Explicit non-goal for this project. CLI parity for `concurrently`/`conc` in package scripts is the product surface; npm package JavaScript remains launcher and install glue only. |
| Windows backend | Upstream supports Windows process semantics. | Windows npm packages are withheld until a Windows-native runner backend exists. |

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
   `Output_formatter`. Passthrough arguments are expanded before command
   construction so `Command.t` still contains the exact shell command that will
   run. Simple npm/yarn/pnpm/bun/node/deno shortcuts and package-script
   wildcards are expanded in the same OS-neutral seam, with generated names
   visible to selectors, `--hide`, and default prefixes.

4. Eio Runner hard cutover

   Replace the blocking Unix runner with an Eio process supervisor. Implement
   true concurrent execution, bounded `max_processes`, real-time stdout/stderr
   events, and close-event collection.

   Status: partially complete. The executable now calls `Runner.run` with
   `Posix_runner_backend.backend`, and the blocking Unix orchestration has been
   deleted. The Runner executes commands concurrently with Eio fibers, bounds
   fan-out with `Run_policy.max_processes`, emits structured output events,
   collects close events, and constructs `Run_result.t`. Restart attempts and
   retry delays keep the command's `max_processes` slot until the command
   succeeds, exhausts finite retries, or is cancelled, matching npm's documented
   queueing rule; retry waits stop early when cancellation closes the command.
   Teardown commands run after the main run drains, emit raw output, and do not
   alter the main exit code.
   Remaining Runner work: stronger process-level parity tests and backend
   conformance tests.

5. Output formatter parity

   Implement prefix modes, raw mode, color policy, prefix length, padding,
   timestamp format, and hidden output. Test formatter behavior without running
   processes.

   Status: partially complete. `lib/output_formatter.ml` now owns labels,
   prefix modes, command-prefix truncation, prefix padding, timestamp prefixes,
   explicit prefix colors, npm-style reset-colored default prefixes, ANSI color
   rendering, no-color mode, internal block formatting, timings output through
   npm's `--timings` flag, global raw output, hidden command output,
   command-level buffering, npm-style command close notifications, PID prefixes
   and `{pid}`
   template placeholders from backend process identity, and deterministic
   no-color and pinned color compatibility tests. Per-command raw flags are
   supported when commands are constructed through `Run_api`. Remaining
   formatter work: broader chalk compatibility and more golden CLI
   compatibility tests.

6. Run policy parity

   Implement kill-others-on success/failure, success condition, restart tries,
   restart delay, exponential restart, signal propagation, and no-start-after
   cancellation semantics.

   Status: partially complete. `--success` now supports `all`, `first`, `last`,
   `command-{index}`, `command-{name}`, and `!command-{index/name}` through the
   OS-neutral `Run_policy` module. `--restart-tries` and `--restart-after` now
   support finite retry counts, fractional/invalid retry-count status
   projection, npm-compatible negative retry-forever counts, fixed millisecond
   delays, invalid-delay timer warning text, and npm-compatible exponential
   delay timing (`2^N` seconds for retry index `N`). Infinite retries keep
   `Run_result` memory
   bounded by collecting only terminal close events while still emitting
   lifecycle output for retry attempts. Killed running siblings stay visible to
   `--success all`, while never-started queued commands are closed internally
   without synthetic killed output after a cancellation condition fires. Retry
   delays remain live after sibling success/failure, matching npm's command
   lifecycle semantics. Remaining run policy work: broader cancellation parity
   around platform-specific signals and Windows process-tree behavior.

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

   Status: partially complete. `npm run compat:concurrently` now compares the
   native binary against pinned `concurrently@9.2.1` for deterministic close
   notifications, failure status, raw/hidden suppression, name prefixes, command
   prefixes, template prefixes, no-prefix mode, prefix padding, grouped
   passthrough placeholders, disabled passthrough behavior, finite restart
   logging, negative restart retry-forever success, teardown status lines,
   raw teardown behavior, PID prefix and template interpolation,
   npm-compatible unknown-option parsing, timing lifecycle
   messages and timing table shape for success, failure, names, hidden output,
  raw suppression, grouped sorted output, finite restart attempts, custom
  timestamp formats, and deterministic kill-on-fail signalling with runtime
  timestamps/durations normalized, published-package ANSI prefix color output
  for reset defaults, `red.bold`, `bgRed.white.bold`, `gray.dim`, `hidden`,
  short/full truecolor hex, and invalid-color fallback, shortcut expansion
  across npm/yarn/pnpm/bun/node/deno runners, package-script and Deno-task
  wildcard expansion,
   kill-others exit projection, raw kill output, kill-on-fail behavior,
   max-process serialization including restart-exhaustion queueing, npm-style
   max-process numeric coercion for zero, invalid, fractional, and negative
   values, fractional/invalid restart-count coercion, deterministic
   restart-after and kill-timeout warning/coercion behavior, queued-command suppression after
   kill-on-success/failure, input forwarding, explicit index and command-name
   input routing, version and help flag aliases, and default input target
   routing. The Ubuntu CI build
   runs this harness after
   `dune build @install @runtest`. Remaining compatibility work: translate more
   upstream behavior tests for duration-order-sensitive
   timing signal cases, broader wildcard and shortcut edge cases, deeper package
   CLI behavior tests, and add backend conformance tests that do not depend on
   npm availability.

9. Npm binary distribution

   Decide and implement the Node-facing package contract. Feature-complete npm
   parity requires ready-to-run native binaries or platform-specific binary
   packages so `conc` works immediately after npm install.

   Status: partially complete. The root package now declares optional platform
   packages for Linux and macOS targets, exposes `concurrently`, `conc`, and
   `concml` npm binaries, and the launcher resolves the matching native package
   before falling back to a local development build. The packed
   root package is restricted to the JS launcher, package metadata, README, and
   LICENSE, so users do not receive OCaml source, tests, Dune files, local
   development scripts, or a JavaScript programmatic API.
   GitHub Actions builds platform packages, smoke-installs the packed root and
   platform package into a clean npm project, asserts the lean root package
   surface, executes `conc`/`concurrently`, and publishes packages on version
   tags. Windows packaging is withheld until a Windows backend exists.
   Remaining distribution work: add checksums or
   SLSA/provenance policy beyond npm provenance, decide whether Linux
   musl/static builds are required, and implement then package Windows runner
   behavior.

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
formatted once, and written once. Formatter work must stay proportional to
emitted lines: prefix rendering, timing lifecycle messages, and global tables
should not introduce per-command global scans on ordinary output chunks.

The control path is process lifecycle. It should keep one bounded queue of
pending commands, one bounded set of running commands, and one close-event list.
For finite restart counts, the close-event maximum is
`command_count * (restart_tries + 1)`. For retry-forever policy, retry failures
are lifecycle output but not result history, so result close-event capacity
stays capped at `command_count`.

`max_processes` must bound process fan-out. Finite restart policy must bound
attempts; infinite restart policy must still bound retained memory. Input
routing must not accumulate unbounded pending writes to a dead command.

## Open Questions

- Which Windows process-tree and shell strategy should the future backend use?
