#!/usr/bin/env bash

set -euo pipefail

port=
led_observed=false
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
poc=$root/esp8266-poc
tools=$poc/tools
elf=$poc/blinky.elf
image=$poc/blinky0x00000.bin

baseline_fingerprint() {
    {
        git -C "$root" diff --raw --no-ext-diff --abbrev=40 -- compiler src/llvm-project src/gcc x.py x x.ps1 config.toml configure bootstrap.example.toml
        git -C "$root" diff --cached --raw --no-ext-diff --abbrev=40 -- compiler src/llvm-project src/gcc x.py x x.ps1 config.toml configure bootstrap.example.toml
        LC_ALL=C git -C "$root" ls-files --others --exclude-standard --directory -- compiler src/llvm-project src/gcc x.py x x.ps1 config.toml configure bootstrap.example.toml tests/assembly-llvm
    } | shasum -a 256 | cut -d ' ' -f 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --port) port=${2:-}; shift 2 ;;
        --led-observed) led_observed=true; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [ -z "$port" ]; then
    printf '%s\n' '--port is required' >&2
    exit 2
fi

[ "$led_observed" = true ] || { printf '%s\n' '--led-observed is required' >&2; exit 2; }

grep -Fqx 'const UART_FIFO: *mut u32 = 0x6000_0000 as *mut u32;' "$poc/src/main.rs"
grep -Fqx 'const UART_CLKDIV: *mut u32 = 0x6000_0014 as *mut u32;' "$poc/src/main.rs"
grep -Fqx 'const UART_STATUS: *mut u32 = 0x6000_001c as *mut u32;' "$poc/src/main.rs"
grep -Fqx 'const UART_TX_FIFO_CAPACITY: u32 = 128;' "$poc/src/main.rs"
grep -Fqx 'const UART_CLKDIV_DIVIDER: u32 = 451;' "$poc/src/main.rs"
grep -Fq 'UART_STATUS.read_volatile() >> 16' "$poc/src/main.rs"
grep -Fq 'UART_FIFO.write_volatile(byte as u32);' "$poc/src/main.rs"
grep -Fqx 'const HALF_PERIOD_CYCLES: u32 = 26_000_000;' "$poc/src/main.rs"
grep -Fqx '            while cycle_count().wrapping_sub(start) < 26_000_000 {' "$poc/src/main.rs"
grep -Fqx '    while cycle_count().wrapping_sub(start) < HALF_PERIOD_CYCLES {}' "$poc/src/main.rs"
[ "$(shasum -a 256 "$poc/src/main.rs" | cut -d ' ' -f 1)" = '30cf4d1ce5c603d14a88bf71ba8d731fe193102514eab1675216b41ce3115b9e' ]
[ "$(baseline_fingerprint)" = '161faafd00056d3558e2b9269473af6257cb928e4ccb149659a3b2adb21c1c0b' ]

PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$tools" python3 -m esptool --chip esp8266 elf2image --use_segments --flash_mode dio --flash_freq 40m --flash_size 4MB --output "$poc/blinky" "$elf"
PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$tools" python3 -m esptool --chip esp8266 --port "$port" --baud 460800 --after hard_reset write_flash 0x00000 "$image"
readback=$(mktemp)
trap 'rm -f "$readback"' EXIT
size=$(wc -c <"$image")
PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$tools" python3 -m esptool --chip esp8266 --port "$port" read_flash 0x00000 "$size" "$readback"

if [ "$(shasum -a 256 "$image" | cut -d ' ' -f 1)" != "$(shasum -a 256 "$readback" | cut -d ' ' -f 1)" ]; then
    printf 'readback=FAIL\n'
    exit 1
fi

if ! PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$tools" python3 - "$port" <<'PY'
import serial
import sys

BAUD = 115200
MIN_PHASE_CYCLES = 25_000_000
MAX_PHASE_CYCLES = 27_000_000
MIN_ACTIVE_BYTES = BAUD // 20 - 32
MAX_ACTIVE_BYTES = BAUD * 11 // 200
ser = serial.Serial(sys.argv[1], BAUD, timeout=0.1)
try:
    ser.dtr = False
    ser.rts = False
    ser.reset_input_buffer()
    frames = 0
    payload = bytearray()
    header = bytearray()
    have_header = False
    for _ in range(120):
        chunk = ser.read(256)
        for byte in chunk:
            if header:
                header.append(byte)
                if len(header) == 18:
                    if header[-1] != ord("\n"):
                        raise SystemExit(1)
                    try:
                        active = int(header[1:9], 16)
                        silence = int(header[9:17], 16)
                    except ValueError:
                        raise SystemExit(1)
                    if not (MIN_PHASE_CYCLES <= active <= MAX_PHASE_CYCLES and
                            MIN_PHASE_CYCLES <= silence <= MAX_PHASE_CYCLES):
                        raise SystemExit(1)
                    header.clear()
                    have_header = True
                continue
            if byte == ord("F"):
                if have_header:
                    if not (MIN_ACTIVE_BYTES <= len(payload) <= MAX_ACTIVE_BYTES):
                        raise SystemExit(1)
                    frames += 1
                    if frames == 2:
                        break
                payload.clear()
                header.append(byte)
            elif have_header and byte == ord("U"):
                payload.append(byte)
            elif have_header:
                raise SystemExit(1)
        if frames == 2:
            break
    if frames < 2:
        raise SystemExit(1)
finally:
    ser.close()
PY
then
    printf 'serial=FAIL\n'
    exit 1
fi

printf 'flash=PASS readback=PASS static=PASS serial=PASS timing=PASS led=PASS\n'
