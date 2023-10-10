#!/bin/bash

hyperfine -N --warmup 40 --min-runs 4000 "/Users/fabianpieringer/my-projects/concurrently-ocaml/concurrently-ml-eio -n tag1,tag2,tag3 'echo test1' 'echo test12' 'echo test13'"

# Determine the platform
if [[ "$(uname -s)" == "Linux" ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
        ./bin/linux-x86_64/my_ocaml_tool "$@"
    else
        ./bin/linux-arm/my_ocaml_tool "$@"
    fi
elif [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
        ./bin/macos-x86_64/my_ocaml_tool "$@"
    else
        /Users/fabianpieringer/my-projects/concurrently-ocaml/concurrently-ml-eio "$@"
    fi
else
    echo "Unsupported platform"
    exit 1
fi
