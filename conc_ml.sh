#!/bin/bash

script_dir="$(dirname "$(readlink -f "$0")")"
build_name_script_path="${script_dir}/build-name.sh"

path=$($build_name_script_path)

cp -L "${path}" "${script_dir}/"
