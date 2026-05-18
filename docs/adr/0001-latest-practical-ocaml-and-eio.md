# ADR 0001: Latest Practical OCaml Toolchain And Eio Runner

## Status

Accepted.

## Context

The project aims to match npm `concurrently` v9 while being faster and simpler
through OCaml. The current repository links `eio` from `bin/dune`, but the
implementation still uses blocking Unix process APIs and immediate `waitpid`,
which makes command execution sequential rather than truly concurrent.

Authoritative version data is split as of 2026-05-18:

- The OCaml releases page lists OCaml 5.4.1 as the latest compiler release,
  dated 2026-02-17.
- The OCaml package versions page and opam `ocaml` virtual package list 5.6.0,
  published 2026-01-26.
- The opam `ocaml-compiler.5.6` package resolves through
  `ocaml-variants.5.6.0+trunk`, describes itself as "Current trunk", and uses
  `https://github.com/ocaml/ocaml/archive/trunk.tar.gz` as its source archive.
- The refreshed opam repository has no `ocaml-base-compiler.5.6.0` package.
- The Dune package page lists Dune 3.23.0 as latest, dated 2026-05-05.
- The Eio package page lists Eio 1.3 as latest and describes it as an
  effect-based direct-style IO API for OCaml with fibers.

## Decision

Use OCaml 5.4.1 as the latest practical stable compiler baseline for this
project, and use Dune 3.23 as the build language/tooling baseline.

Use Eio as the Runner foundation. The hard cutover architecture removes the
current blocking Unix runner instead of preserving it as a second path.

Do not target opam `ocaml-compiler.5.6` yet. It is useful signal for upcoming
compiler work, but the concrete compiler path is trunk-backed rather than a
stable `ocaml-base-compiler` release.

## Consequences

- The project can use OCaml 5 effect-era runtime behavior and modern Dune
  package generation while staying on a stable compiler release.
- Runner tests should exercise Eio fibers, cancellation, streaming output,
  restart policy, and signal handling directly.
- Future upgrade to OCaml 5.6 must be a hard cutover ADR or ADR amendment, not a
  compatibility branch.
- CI must install opam, OCaml 5.4.1, Dune 3.23, Eio 1.3, Cmdliner 2.x, and
  ANSITerminal before build/test checks can be authoritative.

## References

- OCaml releases: https://ocaml.org/releases
- opam ocaml-compiler: https://opam.ocaml.org/packages/ocaml-compiler/
- Dune versions: https://ocaml.org/p/dune/latest/versions
- Eio package: https://opam.ocaml.org/packages/eio/
- npm concurrently releases: https://github.com/open-cli-tools/concurrently/releases
