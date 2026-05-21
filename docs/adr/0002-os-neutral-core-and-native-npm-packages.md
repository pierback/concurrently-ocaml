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
and Windows x64/arm64. The 2026 GitHub-hosted runner reference lists Linux
arm64 labels such as `ubuntu-24.04-arm`, macOS arm64 labels including
`macos-26`, Windows x64 labels including `windows-latest`, and Windows arm64
labels including `windows-11-arm`. Native Windows ARM64 packaging is not part
of the supported surface because `ocaml/setup-ocaml@v3` cannot provision opam
for `windows/arm64`.

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
- POSIX process-group stubs and the `eio_posix` dependency live in the
  `concurrentlyocaml_posix` backend library. The core `concurrentlyocaml`
  library remains the OS-neutral CLI/domain model and runner orchestration.
- Windows implementations must use Windows-native process tree teardown instead
  of pretending POSIX signals are portable.
- The Windows backend uses `cmd.exe /d /s /c` for shell command execution and a
  Win32 job object to terminate the shell process tree.

Distribute npm packages as:

- Root package: `@pierback/concurrently-ml`, containing the JS launcher,
  repo-owned native-backed JavaScript API facade, and optional native platform
  dependencies.
- POSIX-compatible platform packages:
  - `@pierback/concurrently-ml-linux-x64-gnu`
  - `@pierback/concurrently-ml-linux-arm64-gnu`
  - `@pierback/concurrently-ml-linux-x64-musl`
  - `@pierback/concurrently-ml-linux-arm64-musl`
  - `@pierback/concurrently-ml-darwin-x64`
  - `@pierback/concurrently-ml-darwin-arm64`
  - `@pierback/concurrently-ml-win32-x64`

Each platform package contains exactly one native binary under `bin/`. The root
launcher resolves the matching optional dependency first when run from an
installed package root. Linux resolution is libc-aware: glibc hosts resolve the
`linux-*-gnu` packages, and musl hosts resolve `linux-*-musl`. Linux platform
packages declare npm's `libc` selector (`glibc` for `*-gnu`, `musl` for
`*-musl`) so npm only installs a binary built for the host C library. In a
source checkout, the launcher prefers
`_build/default/bin/main.exe` so local npm smoke tests exercise the current Dune
build before falling back to an optional package.

GitHub Actions builds and tests each native target from source with OCaml
5.4.1, packs the platform package, uploads it as an artifact, and publishes
platform packages before the root package on version tags.
Darwin package jobs set `MACOSX_DEPLOYMENT_TARGET` before dependency
installation and compilation so the runner image version does not become the
minimum supported macOS version for the shipped Mach-O binary.
Windows package jobs build and smoke-install the `win32-x64` native package.
They also compare Windows-safe CLI fixtures against pinned
`concurrently@9.2.1` and run a native job-object cleanup smoke against the
local binary. The root npm bin shim must not route Windows hosts to the pinned
upstream JavaScript CLI.

## Consequences

- npm install no longer requires local OCaml tooling once platform packages are
  published.
- The core domain modules remain reusable and testable without OS-specific
  fixtures.
- Runner parity work must define behavior at the backend interface, not by
  leaking Unix assumptions into `Command` or `Run_policy`.
- The executable selects a native backend at build time. Platforms without a
  backend fail with an explicit native-backend error while Windows support is in
  progress; they do not route to upstream JavaScript.
- Alpine/musl users do not accidentally execute a glibc binary. They install
  and smoke the dedicated `linux-*-musl` package instead.
- Windows drop-in npm-script behavior comes from explicit Windows process
  supervision, not accidental compatibility through upstream JavaScript, POSIX
  shell strings, or POSIX signal names.
- JavaScript imports also avoid upstream `concurrently`; unsupported
  JavaScript-only extension hooks fail explicitly until they are implemented in
  this repo.

## References

- GitHub-hosted runners reference:
  https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- Choosing GitHub-hosted runners:
  https://docs.github.com/en/actions/writing-workflows/choosing-where-your-workflow-runs/choosing-the-runner-for-a-job
