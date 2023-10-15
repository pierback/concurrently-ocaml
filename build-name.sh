#!/bin/bash

# Determine the platform
if [[ "$(uname -s)" == "Linux" ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
        mkdir -p ./exec/linux-x86_64/
        echo ./exec/linux-x86_64/concurrently-ml
    else
        mkdir -p ./exec/linux-arm/
        echo ./exec/linux-arm/concurrently-ml
    fi
elif [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
        mkdir -p ./exec/macos-x86_64/
        echo ./exec/macos-x86_64/concurrently-ml
    else
        mkdir -p ./exec/macos-arm/
        echo ./exec/macos-arm/concurrently-ml
    fi
else
    echo "Unsupported platform"
    exit 1
fi
