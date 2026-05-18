(lang dune 3.23)

(name concurrentlyocaml)

(generate_opam_files true)

(source
 (github pierback/concurrently-ocaml))

(authors "Franz Pieringer")

(maintainers "Franz Pieringer")

(license MIT)

(documentation https://github.com/pierback/concurrently-ocaml)

(package
 (name concurrentlyocaml)
 (synopsis "OCaml command runner compatible with npm concurrently")
 (description
  "A hard-cutover OCaml 5 command runner targeting feature parity with npm concurrently.")
 (depends
  (ocaml
   (>= 5.4.1))
  (dune
   (>= 3.23))
  (eio
   (>= 1.3))
  (eio_posix
   (>= 1.3))
  (eio_main
   (>= 1.3))
  (cmdliner
   (>= 2.0.0))
  ANSITerminal)
 (tags
  ("cli" "process" "concurrency" "ocaml" "eio")))
