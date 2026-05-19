# Project Context

## Domain

`concurrently-ocaml` is a command runner for starting, supervising, and
formatting output from multiple shell commands. The target behavior is feature
parity with npm `concurrently` v9 while using OCaml 5 and Eio to keep process
supervision fast, explicit, and testable. The core domain model is OS-neutral;
platform-specific behavior belongs behind runner backends and native
distribution packaging.

## Terms

- Command: one user-supplied shell command string plus optional command-local
  metadata such as name, cwd, environment, prefix color, raw output mode, and
  IPC intent.
- Run: one invocation of the tool over a non-empty command list and one run
  policy.
- CLI config: validated immutable command-line input converted into commands,
  display config, and run policy before any command execution begins.
- Run API: validated programmatic input for OCaml callers. It accepts
  structured commands and run/display/input options, then produces the same
  command model, run spec, input router, and formatter options as the CLI path.
- Npm binary package: the JavaScript launcher and optional native platform
  packages that make `concurrently` and `conc` resolve to the OCaml binary after
  npm install. JavaScript is packaging glue only, not a programmatic API.
- Runner: the module that owns command lifecycle: spawn, stream, restart, kill,
  wait, and close-event collection.
- Runner backend: the platform-specific adapter that owns process spawning,
  signaling, process-tree teardown, stdin/stdout/stderr pipes, process
  identity, and platform error mapping for one OS family.
- Run policy: immutable configuration that decides max parallelism, restart
  behavior, kill behavior, success condition, teardown, and signal handling.
- Output event: a bounded chunk of stdout, stderr, lifecycle, timing, or error
  information emitted by a command.
- Output formatter: the module that turns output events into bytes written to
  the selected output stream.
- Prefix: the per-line label attached to formatted command output. Prefixes can
  be index, pid, time, command, name, none, or a template.
- Input router: the module that forwards user input to one command or a selected
  command target.
- Close event: the final observed result for a command attempt, including exit
  code or signal, killed status, start time, end time, and duration.
- Attempt: one execution of a command. A restarted command has multiple attempts
  but one stable command identity.
- Teardown command: a command that runs after the main run reaches completion or
  cancellation.
- Platform package: an npm optional dependency containing one native binary for
  one `os`/`cpu` target, resolved by the root package launcher.

## Architecture Vocabulary

- Module: anything with an interface and an implementation.
- Interface: everything a caller must know to use a module, including types,
  invariants, error modes, ordering, and config.
- Implementation: code inside the module.
- Depth: leverage at the interface. A deep module hides substantial behavior
  behind a small interface.
- Seam: where an interface lives and behavior can be altered without editing in
  place.
- Adapter: a concrete implementation satisfying an interface at a seam.
- Leverage: what callers get from depth.
- Locality: what maintainers get from depth.

## TigerStyle Constraints

- Use hard cutovers. Do not keep the current blocking Unix runner as a
  compatibility path once the Eio Runner exists.
- Make invalid states loud with parse-time validation and assertions at module
  seams.
- Bound every fan-out: commands, running processes, restarts, buffered output,
  pending commands, input routing, and teardown work.
- Keep operating errors explicit: spawn failure, signal failure, write failure,
  malformed CLI config, restart exhaustion, and cancellation.
- Separate control plane from data plane. Run policy and lifecycle decisions are
  control plane; streaming command output is data plane.
- Keep OS-specific process semantics out of core domain modules. Put Unix
  process groups, Windows process trees, and shell selection behind runner
  backend interfaces.
