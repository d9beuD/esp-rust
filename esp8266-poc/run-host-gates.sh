#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target=xtensa-esp8266-none-elf
linker=$root/esp8266-poc/toolchain/bin/xtensa-lx106-elf-gcc
tools=$root/esp8266-poc/tools
config=$root/esp8266-poc/bootstrap.toml

cd "$root"

bootstrap() {
    bash "$root/esp8266-poc/bootstrap-lx106-toolchain.sh" --cmake
    export PATH="$tools/bin:$PATH"
    export PYTHONPATH="$tools${PYTHONPATH:+:$PYTHONPATH}"
}

rustc() {
    local candidates=("$root"/build/*/stage1/bin/rustc)
    if [ -x "${candidates[0]}" ]; then
        printf '%s\n' "${candidates[0]}"
        return
    fi
    bootstrap >&2
    python3 "$root/x.py" --config "$config" build --stage 1 compiler/rustc >&2
    candidates=("$root"/build/*/stage1/bin/rustc)
    [ -x "${candidates[0]}" ]
    printf '%s\n' "${candidates[0]}"
}

case "${1:-}" in
    investigate)
        grep -Fq 'https://github.com/d9beuD/esp-rust.git' "$root/../esp-rust-build/support/rust-build/x86_64-unknown-linux-gnu/build.sh"
        grep -Fq 'repository: d9beuD/esp-rust' "$root/../esp-rust-build/.github/workflows/build-rust-src.yaml"
        printf '%s\n' '{"fork_source":"https://github.com/d9beuD/esp-rust.git","maintenance_break":"build scripts previously checked out esp-rs/rust"}'
        ;;
    compiler)
        bootstrap
        "$(rustc)" --print target-list | grep -Fx "$target"
        ;;
    core)
        bootstrap
        BOOTSTRAP_SKIP_TARGET_SANITY=1 python3 "$root/x.py" --config "$config" build --stage 1 library/core --target "$target"
        printf 'core=PASS\n'
        ;;
    blinky)
        bootstrap
        bash "$root/esp8266-poc/bootstrap-lx106-toolchain.sh"
        compiler=$(rustc)
        BOOTSTRAP_SKIP_TARGET_SANITY=1 python3 "$root/x.py" --config "$config" build --stage 1 library --target "$target"
        startup="$root/esp8266-poc/start.o"
        "$linker" -c -nostdlib -o "$startup" "$root/esp8266-poc/start.S"
        "$compiler" --sysroot "$(dirname "$(dirname "$compiler")")" --target "$target" -C linker="$linker" -C link-arg=-nostartfiles -C link-arg=-Wl,-T,"$root/esp8266-poc/link.x" -C link-arg="$startup" -C opt-level=s --emit link -o "$root/esp8266-poc/blinky.elf" "$root/esp8266-poc/src/main.rs"
        printf 'blinky=PASS\n'
        ;;
    a6-spill)
        bootstrap
        python3 "$root/x.py" --config "$config" test tests/assembly-llvm/asm/xtensa-esp8266-a6-spill.rs --test-args --ignored
        printf 'a6_spill=PASS\n'
        ;;
    *)
        printf 'usage: %s {investigate|compiler|core|blinky|a6-spill}\n' "$0" >&2
        exit 2
        ;;
esac
