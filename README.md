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
npm run audit:npm-api
npm run compat:concurrently
npm run smoke:npm-install:host
```

## Current Packaging State

The root npm package ships the JavaScript ESM entrypoint shape from
`concurrently@10.0.0`, TypeScript declarations, CLI shims, and optional platform packages containing native
`concurrently-ml` binaries for macOS, Linux GNU, Linux musl, and Windows.
During local development the launcher can also use `_build/default/bin/main.exe`
after `npm run compile`.

For drop-in npm-script usage, install this package under the public
`concurrently` package name:

```sh
npm install --save-dev concurrently@npm:@pierback/concurrently-ml
```

That keeps existing `concurrently`/`conc` package scripts and
`require("concurrently")` imports pointed at this package.

JavaScript and TypeScript callers can use the same package entrypoint shape as
npm `concurrently`:

```ts
import concurrently from "concurrently";

const { result } = concurrently(["npm run dev", "npm test"], {
  killOthersOn: ["failure"],
});

await result;
```

CommonJS callers use the same alias:

```js
const { default: concurrently } = require("concurrently");

concurrently(["node server.js", "npm run watch"]);
```

The package requires Node.js 22 or newer, matching `concurrently@10.0.0`.

`npm run smoke:npm-install:host` packages the current host binary, installs the
root package plus matching platform package into a clean temporary npm project,
installs the root package under the `concurrently` alias, and verifies the
`conc` and `concurrently` bin shims resolve to the native binary. It supports
macOS x64/arm64, Linux GNU and Linux musl x64/arm64, and Windows x64.

Windows npm-script execution no longer falls back to upstream JavaScript. The
Windows backend uses a native `cmd.exe` shell launch path and Windows job
objects for process-tree teardown behind `Runner_backend.t`.

The packed root npm package is intentionally lean: it contains the native
launcher, package metadata, JavaScript API facade, README, and LICENSE only.
OCaml source, Dune/opam metadata, tests, and development scripts stay out of
the install payload.

Linux platform packages are libc-specific. glibc hosts install
`linux-*-gnu`, while Alpine/musl hosts install `linux-*-musl` through npm's
`libc` package selector (`glibc` or `musl`). Windows platform packages ship
`concurrently-ml.exe`.

## Library Scope

OCaml callers can bypass CLI parsing with `Concurrentlyocaml.Run_api`. The
module accepts structured commands with command-local `name`, `cwd`, `env`,
`prefix_color`, `raw`, `hidden`, and `ipc` fields, validates them into the same
`Command.t`/`Run_spec.t` model as the CLI, and runs through the explicit
`Runner_backend.t` seam.

The npm package keeps both the CLI path and the JavaScript programmatic facade
native-backed on supported platforms. `require("concurrently")` and ESM imports
return a repo-owned facade that spawns the native binary and exposes the
upstream-compatible entrypoint names. The facade supports command-local `cwd`,
`env`, `prefixColor`, `raw`, and `hidden` values by carrying that metadata into
the native run. `options.logger` is accepted as the output sink for native
stdout/stderr, and `Logger.output` exposes upstream-shaped `{ command, text }`
events. Custom controllers can inspect or replace the native-backed command
list, receive close, timer, and state-change events from the facade, and kill
returned commands through native per-command control files or an `options.kill`
callback after the child PID is known. Standalone `new Command` instances
support custom `spawn` and IPC for controller-style library code. The command,
logger, and IPC observable surfaces are backed by `rxjs` subjects to preserve
the upstream JavaScript API shape. High-level runs with `options.spawn`,
command-level `ipc`, command-aware logger callbacks, custom kill callbacks,
and teardown commands use the package-owned JavaScript scheduler so callers get
per-command Node child-process context without routing to upstream JavaScript.

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
`concurrently@9.2.1`; `npm run audit:npm-api` verifies the packaged JavaScript
entrypoint and type surface against `concurrently@10.0.0`.
