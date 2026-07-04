# Handoff

Date: 2026-07-04

## Repository

- Path: `/Users/f.pieringer/projects/concurrently-ocaml`
- GitHub: https://github.com/pierback/concurrently-ocaml
- Branch: `master`
- Purpose: concurrently-ocaml is an OCaml 5 command runner targeting feature parity with npm `concurrently`, packaged as a Node-compatible CLI/library facade with native binaries and TypeScript declarations.

## Setup, Run, Test

- Initial OCaml switch setup: `npm run setup:opam`
- Build: `npm run build`
- Test: `npm test`
- Compile CLI binary: `npm run compile`
- npm API audit: `npm run audit:npm-api`
- Compatibility check: `npm run compat:concurrently`
- Host package smoke test: `npm run smoke:npm-install:host`

## Current State

- The repo already had `origin` at `https://github.com/pierback/concurrently-ocaml.git`.
- The local `master` branch was ahead of `origin/master` before this checkpoint.
- The working tree included an untracked `.codex-fable5/` review ledger/finding state; it is included in this checkpoint.
- Recent local metadata includes `QA_FINDINGS.md` and resolved `.codex-fable5` findings around teardown runner behavior.
- No verification commands were run as part of this checkpoint/push handoff.

## Known Risks and Open Loops

- `_opam`, `_build`, `node_modules`, and generated packaging output exist locally but are governed by the repo's existing ignore/tracking rules.
- The branch name is `master`, not `main`; preserve that unless intentionally cutting over the branch.
- The package targets Node.js 22 or newer and OCaml 5.4.1 by default.

## Next Steps on Another Mac

1. Clone with `git clone https://github.com/pierback/concurrently-ocaml.git`.
2. Check out `master`.
3. Run `npm install` if needed for Node-side tooling.
4. Run `npm run setup:opam` once to create the repo-local switch.
5. Run `npm run build`, `npm test`, `npm run audit:npm-api`, and relevant smoke/compatibility checks before publishing or refactoring.
