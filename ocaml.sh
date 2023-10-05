#!/bin/bash

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
        /Users/fabianpieringer/my-projects/concurrentlyocaml/my_script "$@"
    fi
else
    echo "Unsupported platform"
    exit 1
fi
