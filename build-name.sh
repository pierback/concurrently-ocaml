#!/bin/bash

script_dir="$(dirname "$(readlink -f "$0")")"

# Determine the platform
if [[ "$(uname -s)" == "Linux" ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
        sudo mkdir -p "${script_dir}/exec/linux-x86_64"
        echo "${script_dir}/exec/linux-x86_64/concurrently-ml"
    else
        sudo mkdir -p "${script_dir}/exec/linux-arm/"
        echo "${script_dir}/exec/linux-arm/concurrently-ml"
    fi
elif [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
        mkdir -p "${script_dir}/exec/macos-x86_64/"
        echo "${script_dir}/exec/macos-x86_64/concurrently-ml"
    else
        mkdir -p "${script_dir}/exec/macos-arm/"
        echo "${script_dir}/exec/macos-arm/concurrently-ml"
    fi
else
    echo "Unsupported platform"
    exit 1
fi
