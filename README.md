# concurrently-ocaml

An OCaml 5 command runner targeting feature parity with npm `concurrently`.

See:

- [Project context](CONTEXT.md)
- [Feature parity architecture plan](docs/architecture/feature-parity-plan.md)
- [ADR 0001: Latest practical OCaml and Eio](docs/adr/0001-latest-practical-ocaml-and-eio.md)

## Local Development

Set up the persistent repo-local OCaml switch once:

```sh
npm run setup:opam
```

That creates `_opam` with OCaml 5.4.1 by default, installs project test
dependencies plus `ocamlformat`, and runs the build/test gate. Override the
compiler with `OCAML_COMPILER=ocaml-base-compiler.<version>` when intentionally
testing a different toolchain.

After setup, use the npm scripts. They run through `opam exec`, so they do not
depend on manually exporting the switch environment:

```sh
npm run build
npm test
npm run compile
npm run compat:concurrently
npm run smoke:npm-install:host
```

## Current Packaging State

The root npm package ships a JavaScript launcher plus optional Linux and macOS
platform packages containing native `concurrently-ml` binaries. During local
development the launcher can also fall back to `_build/default/bin/main.exe`
after `npm run compile`.

For drop-in npm-script usage, install this package under the public
`concurrently` package name:

```sh
npm install --save-dev concurrently@npm:@pierback/concurrently-ml
```

That keeps existing `concurrently`/`conc` package scripts and
`require("concurrently")` imports pointed at this package.

`npm run smoke:npm-install:host` packages the current host binary, installs the
root package plus matching platform package into a clean temporary npm project,
installs the root package under the `concurrently` alias, and verifies the
`conc` and `concurrently` bin shims resolve to the native binary. It currently
supports macOS x64/arm64 and Linux GNU x64/arm64; musl and Windows remain
withheld until real build/backend targets exist.

The packed root npm package is intentionally lean: it contains the native
launcher, package metadata, JavaScript API facade, README, and LICENSE only.
OCaml source, Dune/opam metadata, tests, and development scripts stay out of
the install payload.

Windows platform packages are intentionally withheld until a Windows runner
backend exists.

## Library Scope

OCaml callers can bypass CLI parsing with `Concurrentlyocaml.Run_api`. The
module accepts structured commands with command-local `name`, `cwd`, `env`,
`prefix_color`, `raw`, `hidden`, and `ipc` fields, validates them into the same
`Command.t`/`Run_spec.t` model as the CLI, and runs through the explicit
`Runner_backend.t` seam.

The npm package keeps the CLI path native while re-exporting the pinned
`concurrently@9.2.1` JavaScript programmatic API through the npm alias
`concurrently-js`. This preserves the upstream `require()`/ESM API shape for
users who install this package under the `concurrently` name while keeping npm
script execution on the OCaml binary.

## Implemented CLI Surface

The current native CLI covers the core process-supervision path: multiple
commands, names, `--name-separator`, prefixes, prefix colors, raw output,
hidden output, `-m`/`--max-processes`, success conditions, restart tries and delays,
process-group kill policies, `--ks`/`--kill-signal`, `--kill-timeout`, PID
prefixes, `--timings`, `--group`, `-i`/`--handle-input`,
`--default-input-target`, `-P`/`--passthrough-arguments`, npm/yarn/pnpm/bun/node/deno
script shortcuts with package-script wildcards, and `--teardown`.
Formatted output includes npm-style command close notifications, while `--raw`
and hidden commands suppress those notifications like npm `concurrently`.
Cancellation status lines are emitted for `-k`/`--kill-others` in formatted
output.

Like npm `concurrently`, CLI flags can also be supplied through
`CONCURRENTLY_*` environment variables, with explicit CLI arguments taking
precedence over environment defaults.

`--max-processes` accepts either an exact integer or a percentage of detected
CPUs, such as `50%`.

`--passthrough-arguments` replaces `{1}`, `{@}`, and `{*}` placeholders in
commands with arguments after `--`.

Shortcuts such as `npm:build` and `npm:build-*` expand like npm
`concurrently`, including wildcard-generated names.

Teardown commands are executed after the main run drains. Their output is raw,
and their exit status does not affect the main run exit code.

Input handling is opt-in like npm `concurrently`: unprefixed stdin is forwarded
to the default target, while `index:` and `name:` prefixes route stdin chunks to
a selected running command.

`npm run compat:concurrently` compares deterministic CLI cases against pinned
`concurrently@9.2.1`.
