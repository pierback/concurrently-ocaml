# Contributing

Thanks for helping improve `concurrently-ocaml`.

## Development setup

You need Node.js 24, npm, and opam. From a fresh clone, run:

```sh
npm run setup:opam
```

This installs the locked npm dependencies, creates the repository-local OCaml
5.4.1 switch, installs development dependencies, and runs the JavaScript and
OCaml test suites.

The opam file is generated from `dune-project`; edit `dune-project`, not
`concurrentlyocaml.opam`, when changing package metadata or dependencies.

## Before opening a pull request

Run the complete local parity gate:

```sh
npm run test:parity
```

If your host is not one of the supported native package targets, run the
individual build and test commands documented in the README and let CI run the
platform package smoke tests.

Changes to CLI or JavaScript API behavior should include a focused regression
test and, when applicable, a deterministic comparison against the pinned
upstream `concurrently` release. Platform-specific process behavior belongs in
the existing POSIX or Windows backend rather than the OS-neutral domain core.

## Pull requests

- Keep each pull request focused on one coherent change.
- Explain the user-visible behavior and the verification performed.
- Update the README or architecture decision records when the public contract
  or an architectural boundary changes.
- Do not commit generated build output, local switches, credentials, or npm
  tokens.

The project uses hard cutovers: remove replaced behavior instead of retaining
deprecated compatibility paths.
