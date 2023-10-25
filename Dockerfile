# Use an official OCaml image as the base image
FROM ocaml/opam2:latest

# Set environment variables
ENV DUNE_CACHE="disabled"

ENV NODE_VERSION=16.13.0

WORKDIR /app

# Install system dependencies
RUN sudo apt install m4 -y
# RUN wget -qO- https://get.pnpm.io/install.sh | ENV="$HOME/.bashrc" SHELL="$(which bash)" bash - && pnpm --version
# RUN wget -qO- https://get.pnpm.io/install.sh | ENV="$HOME/.shrc" SHELL="$(which sh)" sh - && pnpm --version

# RUN pnpm --version
# RUN ls /app/home
# RUN ls /app/home/opam/
# RUN source /app/home/opam/.bashrc

# RUN sudo apt-get install -y nodejs

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
RUN opam install ANSITerminal
RUN opam install ansiterminal

# Build the binary
RUN sudo mkdir -p exec && sudo chmod 755 exec
RUN ls bin
RUN opam exec -- dune --version
# RUN pnpm run compile
RUN opam exec -- ocamlfind ocamlopt -linkpkg -thread -package unix,ANSITerminal bin/main.ml -o $(./build-name.sh)

# Copy the binary to the /app directory
# RUN cp _build/default/bin/main.exe build/main

# Clean up
RUN opam clean -a -c

# Set the entry point to the built binary
