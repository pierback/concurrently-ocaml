# ADR 0002: OS-Neutral Core And Native npm Platform Packages

## Status

Accepted.

## Context

The project target now includes cross-platform native distribution. Users should
be able to install the npm package and run `conc` without installing OCaml,
opam, Dune, or a compiler locally.

Process supervision is inherently platform-specific. Unix-like systems need
process-group and signal behavior. Windows needs a different process tree and
console-control strategy. The domain model should not encode either strategy.

GitHub-hosted runner labels are available for Linux x64/arm64, macOS x64/arm64,
and Windows x64. The 2026 GitHub-hosted runner reference lists Linux arm64
labels such as `ubuntu-24.04-arm`, macOS arm64 labels including `macos-26`, and
Windows x64 labels including `windows-latest`.

## Decision

Keep `Command`, `Run_policy`, `Run_spec`, `Output_event`, `Close_event`,
`Run_result`, `Cli_config`, and `Output_formatter` OS-neutral.

Split process supervision behind a backend boundary before adding Windows
behavior:

- `Runner` remains the public orchestration entrypoint.
- The `Runner_backend` interface owns spawn, signal, process-tree
  termination, stdout/stderr pipe capture, and platform error mapping.
- Unix-like implementations use Eio POSIX process handles plus process-group
  teardown.
- Windows implementations must use Windows-native process tree teardown instead
  of pretending POSIX signals are portable.

Distribute npm packages as:

- Root package: `@pierback/concurrently-ml`, containing the JS launcher and
  optional dependencies.
- POSIX-compatible platform packages:
  - `@pierback/concurrently-ml-linux-x64`
  - `@pierback/concurrently-ml-linux-arm64`
  - `@pierback/concurrently-ml-darwin-x64`
  - `@pierback/concurrently-ml-darwin-arm64`

Each platform package contains exactly one native binary under `bin/`. The root
launcher resolves the matching optional dependency first when run from an
installed package root. In a source checkout, it prefers
`_build/default/bin/main.exe` so local npm smoke tests exercise the current Dune
build before falling back to an optional package.

GitHub Actions builds and tests each POSIX-compatible target from source with
OCaml 5.4.1, packs the platform package, uploads it as an artifact, and
publishes platform packages before the root package on version tags.
Darwin package jobs set `MACOSX_DEPLOYMENT_TARGET` before dependency
installation and compilation so the runner image version does not become the
minimum supported macOS version for the shipped Mach-O binary.

Do not publish Windows packages until there is a Windows-native backend. The
current POSIX backend uses `/bin/sh`, POSIX process groups, and POSIX signals;
those details must remain behind `Runner_backend.t`.

## Consequences

- npm install no longer requires local OCaml tooling once platform packages are
  published.
- The core domain modules remain reusable and testable without OS-specific
  fixtures.
- Runner parity work must define behavior at the backend interface, not by
  leaking Unix assumptions into `Command` or `Run_policy`.
- Windows support is withheld until it is explicit backend work, not accidental
  compatibility through shell strings and POSIX signal names.

## References

- GitHub-hosted runners reference:
  https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- Choosing GitHub-hosted runners:
  https://docs.github.com/en/actions/writing-workflows/choosing-where-your-workflow-runs/choosing-the-runner-for-a-job
