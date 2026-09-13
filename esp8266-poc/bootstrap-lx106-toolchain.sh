#!/usr/bin/env bash

set -euo pipefail

toolchain=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolchain
tools=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools
archive=$toolchain/xtensa-lx106-elf-gcc8_4_0-esp-2020r3-macos.tar.gz
url=https://dl.espressif.com/dl/xtensa-lx106-elf-gcc8_4_0-esp-2020r3-macos.tar.gz

if [ ! -x "$tools/bin/cmake" ]; then
    python3 -m pip install --disable-pip-version-check --target "$tools" cmake==3.31.6
fi

if [ ! -d "$tools/esptool" ]; then
    python3 -m pip install --disable-pip-version-check --target "$tools" esptool==4.12.0
fi

if [ "${1:-}" = --cmake ]; then
    exit 0
fi

if [ -x "$toolchain/bin/xtensa-lx106-elf-gcc" ]; then
    exit 0
fi

mkdir -p "$toolchain"
curl -fL --retry 3 -o "$archive" "$url"
tar -xzf "$archive" -C "$toolchain" --strip-components=1
rm -f "$archive"
"$toolchain/bin/xtensa-lx106-elf-gcc" --version
