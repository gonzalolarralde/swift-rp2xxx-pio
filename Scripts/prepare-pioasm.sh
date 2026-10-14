#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=079c6f39023649b154152db30f1d781e884879bc
destination=.build/pioasm-reference
mkdir -p "$destination"
if [[ ! -f "$destination/tools/pioasm/CMakeLists.txt" ]]; then
    curl -fsSL "https://codeload.github.com/raspberrypi/pico-sdk/tar.gz/$revision" |
        tar -xz -C "$destination" --strip-components=1
fi
cmake -S "$destination/tools/pioasm" -B "$destination/build" \
    -DPIOASM_VERSION_STRING=2.2.1-reference
cmake --build "$destination/build"
