#!/bin/bash

script_dir="$(dirname "$(readlink -f "$0")")"
build_name_script="${script_dir}/build-name.sh"

$($build_name_script) "$@"