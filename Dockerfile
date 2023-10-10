# Use an official OCaml image as the base image
FROM ocaml/opam2:latest

# Set environment variables
ENV DUNE_CACHE="disabled"

# Create a working directory
WORKDIR /app

# Install system dependencies
RUN sudo apt install m4 -y

# Copy the source code to the container
COPY . /app
# Switch to the user

# Run the command with opam exec
# Install OCaml dependencies
# RUN opam switch list-available
# RUN opam switch create 4.14.0
# RUN opam switch set-default my-ocaml
RUN sudo mkdir -p bin && sudo chmod 755 bin

USER root
RUN opam init

RUN opam init --disable-sandboxing
RUN eval $(opam env)
RUN opam update
RUN opam install dune
RUN opam install --deps-only .
RUN opam install ocamlfind

# Build the binary
RUN sudo mkdir -p build && sudo chmod 755 build
RUN ls bin
RUN opam exec -- dune --version
RUN opam exec -- ocamlfind ocamlopt -o build/linux-concurrently-ml -package unix -linkpkg bin/main.ml
# RUN opam exec -- ocamlfind  -c bin/main.mli ocamlopt -o linux-concurrently-ml -package unix -linkpkg bin/main.ml

# Copy the binary to the /app directory
# RUN cp _build/default/bin/main.exe build/main

# Clean up
RUN opam clean -a -c
RUN ls build

# Set the entry point to the built binary
