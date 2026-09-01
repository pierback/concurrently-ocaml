#!/usr/bin/env sh
set -eu

compiler="${OCAML_COMPILER:-ocaml-base-compiler.5.4.1}"

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to install the locked JavaScript dependencies" >&2
  exit 127
fi

if ! command -v opam >/dev/null 2>&1; then
  echo "opam is required to set up the local OCaml switch" >&2
  exit 127
fi

npm ci --ignore-scripts --no-audit --no-fund

if [ ! -d "_opam" ]; then
  opam switch create . "$compiler" --yes --no-install
fi

opam install . --deps-only --with-test --yes
opam install ocamlformat --yes

npm run test:api
opam exec -- dune build @install @runtest
