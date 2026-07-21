# Upstream Parity Authority

The parity authority is npm `concurrently@10.0.0`, built from
[`open-cli-tools/concurrently` commit `cf2eaa2b0fd36cc9f1eaf1f8c56de8d21bd0a42c`](https://github.com/open-cli-tools/concurrently/tree/cf2eaa2b0fd36cc9f1eaf1f8c56de8d21bd0a42c).
The version, commit, npm integrity, and reference-suite counts live in
[`scripts/ci/upstream-reference.json`](../../scripts/ci/upstream-reference.json).
Do not introduce another loose upstream version constant.

## Executable Gate

Run the complete local gate with:

```sh
npm run test:parity
```

It runs the OCaml build and tests, checks the packed JavaScript and TypeScript
surface against the integrity-pinned npm tarball, compares deterministic CLI
and JavaScript API behavior with upstream, and installs the packed host binary
in a clean npm project.

Every differential case names the upstream test or published behavior that it
represents. A green local gate is required for parity, but it is not permission
to claim that the entire upstream suite passes.

## The Final Boss

The pinned upstream revision contains 630 unit tests and 4 smoke tests. Those
634 tests are the final coverage inventory. Most unit tests import upstream
TypeScript internals, so running them unchanged only tests upstream itself; it
does not test this OCaml implementation.

Parity is complete only when every upstream public behavior is either:

1. exercised against this package by an adapted upstream test;
2. covered by a byte-for-byte differential case or an equivalent native test;
3. recorded as implementation-only or intentionally divergent, with a reason.

The remaining high-value adapters are the upstream `concurrently`, `Command`,
flow-controller, and `Logger` specs. In particular, exported controller
behavior, low-level `createConcurrently`, and standalone logger coloring must
not be declared compatible based only on matching export and prototype shapes.

To verify that the reference suite itself is healthy:

```sh
git clone https://github.com/open-cli-tools/concurrently.git
git -C concurrently checkout cf2eaa2b0fd36cc9f1eaf1f8c56de8d21bd0a42c
cd concurrently
corepack pnpm install --frozen-lockfile
corepack pnpm test -- --run
corepack pnpm build
corepack pnpm test:smoke -- --run
```

This reference run must report 630 unit tests and 4 smoke tests. It establishes
the target; `npm run test:parity` establishes how much of that target this port
currently proves.
