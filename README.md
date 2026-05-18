# concurrently-ocaml

An OCaml 5 command runner targeting feature parity with npm `concurrently`.

See:

- [Project context](CONTEXT.md)
- [Feature parity architecture plan](docs/architecture/feature-parity-plan.md)
- [ADR 0001: Latest practical OCaml and Eio](docs/adr/0001-latest-practical-ocaml-and-eio.md)

## Current Packaging State

The root npm package ships a JavaScript launcher plus optional Linux and macOS
platform packages containing native `concurrently-ml` binaries. During local
development the launcher can also fall back to `_build/default/bin/main.exe`
after `npm run compile`.

Windows platform packages are intentionally withheld until a Windows runner
backend exists.

## Implemented CLI Surface

The current native CLI covers the core process-supervision path: multiple
commands, names, `--name-separator`, prefixes, prefix colors, raw output,
hidden output, `-m`/`--max-processes`, success conditions, restart tries and delays,
process-group kill policies, `--ks`/`--kill-signal`, `--kill-timeout`, PID
prefixes, `--timings`, `-i`/`--handle-input`, `--default-input-target`, and
`--teardown`.

Teardown commands are executed after the main run drains. Their output is raw,
and their exit status does not affect the main run exit code.

Input handling is opt-in like npm `concurrently`: unprefixed stdin is forwarded
to the default target, while `index:` and `name:` prefixes route one input line
to a selected running command.
