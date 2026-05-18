FROM ocaml/opam:debian-12-ocaml-5.4

ENV DUNE_CACHE="disabled"

WORKDIR /home/opam/app

COPY --chown=opam:opam . /home/opam/app

RUN opam update
RUN opam install . --deps-only --with-test
RUN opam exec -- dune build @install @runtest
RUN cp _build/default/bin/main.exe /home/opam/app/concurrently-ml
RUN opam clean -a -c
