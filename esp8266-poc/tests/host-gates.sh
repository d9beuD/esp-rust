#!/usr/bin/env bash
# Run with: bash esp8266-poc/tests/host-gates.sh
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
poc=$root/esp8266-poc
failures=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

expect_source_regex() {
    local name=$1 pattern=$2
    if ! grep -Eq -- "$pattern" "$poc/src/main.rs"; then
        fail "$name"
        printf 'expected src/main.rs pattern: %s\n' "$pattern" >&2
    fi
}

expect_source_absent() {
    local name=$1 pattern=$2
    if grep -Eq -- "$pattern" "$poc/src/main.rs"; then
        fail "$name"
        printf 'forbidden src/main.rs pattern: %s\n' "$pattern" >&2
    fi
}

firmware_source_is_expected() {
    grep -Eq '0x6000_0000' "$poc/src/main.rs" &&
        grep -Eq '0x6000_0014' "$poc/src/main.rs" &&
        grep -Eq '0x6000_001c' "$poc/src/main.rs" &&
        grep -Eq 'const [A-Z0-9_]*FIFO[A-Z0-9_]*CAPACITY[A-Z0-9_]*: u32 = 128;' "$poc/src/main.rs" &&
        grep -Eq 'const [A-Z0-9_]*(CLKDIV|DIVIDER)[A-Z0-9_]*: u32 = 451;' "$poc/src/main.rs" &&
        grep -Eq '(>> 16|16\.\.=23|16\.\.24)' "$poc/src/main.rs" &&
        grep -Eq 'while .*(UART_STATUS|0x6000_001c).*128|while .*128.*(UART_STATUS|0x6000_001c)' "$poc/src/main.rs" &&
        grep -Eq '26_000_000' "$poc/src/main.rs" &&
        grep -Fqx 'const IO_MUX_GPIO2: *mut u32 = 0x6000_0838 as *mut u32;' "$poc/src/main.rs" &&
        grep -Fqx 'const LED: u32 = 1 << 2;' "$poc/src/main.rs"
}

# Compile and execute pure UART write-admission policy from firmware.  Register
# access remains target-only, but this seam must reject a full FIFO and must
# re-check the active-phase deadline after polling lets a slot open.
firmware_uart_activity_properties_are_expected() {
    python3 - "$poc/src/main.rs" <<'PY'
import pathlib
import re
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
signature = re.search(
    r"fn uart_write_permitted\(tx_fifo_count: u32, start: u32, now: u32\) -> bool\s*\{",
    source,
)
assert signature, "firmware must expose pure uart_write_permitted policy seam"

body_start = source.index("{", signature.start())
depth = 0
for body_end in range(body_start, len(source)):
    if source[body_end] == "{":
        depth += 1
    elif source[body_end] == "}":
        depth -= 1
        if depth == 0:
            break
else:
    raise AssertionError("uart_write_permitted body is not balanced")

policy = source[signature.start():body_end + 1]
test_source = f"""
const HALF_PERIOD_CYCLES: u32 = 26_000_000;
{policy}

#[test]
fn fifo_boundary_and_deadline_crossing_control_writes() {{
    let start = 0x4000_0000;
    assert!(uart_write_permitted(0, start, start));
    assert!(uart_write_permitted(127, start, start + HALF_PERIOD_CYCLES - 1));
    assert!(!uart_write_permitted(128, start, start + HALF_PERIOD_CYCLES - 1));
    assert!(!uart_write_permitted(127, start, start + HALF_PERIOD_CYCLES));
    assert!(!uart_write_permitted(127, start, start + HALF_PERIOD_CYCLES + 1));
}}

#[test]
fn fifo_slot_opening_after_deadline_never_permits_write() {{
    let start: u32 = 0xffff_fff0;
    let full_before_deadline = start.wrapping_add(HALF_PERIOD_CYCLES - 1);
    let slot_opens_at_deadline = start.wrapping_add(HALF_PERIOD_CYCLES);
    assert!(!uart_write_permitted(128, start, full_before_deadline));
    assert!(!uart_write_permitted(127, start, slot_opens_at_deadline));
}}
"""

with tempfile.TemporaryDirectory() as directory:
    test_file = pathlib.Path(directory) / "uart_write_policy.rs"
    test_binary = pathlib.Path(directory) / "uart_write_policy"
    test_file.write_text(test_source)
    subprocess.run(
        ["rustc", "--test", str(test_file), "-o", str(test_binary)], check=True
    )
    subprocess.run([str(test_binary)], check=True)

assert source.count("cycle_count().wrapping_sub(start) < 26_000_000") == 1
assert "cycle_count().wrapping_sub(start) < HALF_PERIOD_CYCLES" in source
assert re.search(
    r"uart_write\(b'U'\);\s*}\s*uart_drain\(\);\s*"
    r"previous_active = cycle_count\(\)\.wrapping_sub\(start\);\s*"
    r"let silence_start = cycle_count\(\);\s*delay\(\);\s*"
    r"previous_silence = cycle_count\(\)\.wrapping_sub\(silence_start\);",
    source,
)
PY
}

# UART0 register values, baud divisor, TX count field, and capacity are hardware
# contract.  TX writes must wait when all 128 FIFO entries are occupied.
expect_source_regex uart0_fifo_register '0x6000_0000'
expect_source_regex uart0_clkdiv_register '0x6000_0014'
expect_source_regex uart0_status_register '0x6000_001c'
expect_source_regex uart0_tx_fifo_count_bits '(>> 16|16\.\.=23|16\.\.24)'
expect_source_regex uart0_fifo_capacity 'const [A-Z0-9_]*FIFO[A-Z0-9_]*CAPACITY[A-Z0-9_]*: u32 = 128;'
expect_source_regex uart0_115200_divider 'const [A-Z0-9_]*(CLKDIV|DIVIDER)[A-Z0-9_]*: u32 = 451;'
expect_source_regex uart0_fifo_full_polling 'while .*(UART_STATUS|0x6000_001c).*128|while .*128.*(UART_STATUS|0x6000_001c)'
expect_source_regex active_phase_is_26m_cycles 'while cycle_count\(\)\.wrapping_sub\(start\) < 26_000_000'
expect_source_regex silent_phase_is_26m_cycles 'while cycle_count\(\)\.wrapping_sub\(start\) < 26_000_000'
expect_source_regex gpio2_mux_is_preserved 'const IO_MUX_GPIO2: \*mut u32 = 0x6000_0838 as \*mut u32;'
expect_source_regex gpio2_led_bit_is_preserved 'const LED: u32 = 1 << 2;'

expect_gate() {
    local name=$1 expected_status=$2 expected_line=$3
    shift 3
    local stdout stderr status
    stdout=$(mktemp)
    stderr=$(mktemp)
    firmware_source_is_expected && bash "$@" >"$stdout" 2>"$stderr"
    status=$?
    if [ "$status" -ne "$expected_status" ] || ! grep -Fqx -- "$expected_line" "$stdout"; then
        fail "$name"
        printf 'expected status: %s; actual status: %s\n' "$expected_status" "$status" >&2
        printf 'expected stdout line: %s\n' "$expected_line" >&2
    fi
    rm -f "$stdout" "$stderr"
}

expect_gate blinky_builds_for_lx106 0 'blinky=PASS' "$poc/run-host-gates.sh" blinky

fixture=$(mktemp -d)
mkdir "$fixture/modules"
cat >"$fixture/modules/esptool.py" <<'PY'
import os
import sys

args = sys.argv[1:]
image = b"uart0-activity-image\n"

if "elf2image" in args:
    with open(args[args.index("--output") + 1] + "0x00000.bin", "wb") as generated:
        generated.write(image)
elif "read_flash" in args:
    with open(args[-1], "wb") as readback:
        readback.write(image if os.environ["READBACK"] == "match" else b"wrong-image\n")
PY
cat >"$fixture/modules/serial.py" <<'PY'
import os

# Firmware reports previous active and silence ccount durations in each next
# activity frame.  Complete frames may arrive fragmented or coalesced.
HEADER = b"F018cba88018cba88\n"
ACTIVE = b"U" * 5742
CYCLE = HEADER + ACTIVE
VALID = [CYCLE[:1703], CYCLE[1703:7000], CYCLE[7000:], CYCLE, CYCLE]
MALFORMED = [HEADER + b"U" * 5700 + CYCLE + CYCLE]
MERGED = [CYCLE * 3]
SHORT_SILENCE = [b"F018cba88004c4b40\n" + ACTIVE + CYCLE + CYCLE]

class Serial:
    def __init__(self, port, baudrate, timeout):
        if port != "fake" or baudrate != 115200:
            raise RuntimeError("UART must open fake at 115200 baud")
        # pyserial read(size) cannot return more than size bytes.  Preserve
        # coalesced wire data while delivering it through that real interface.
        self.buffer = bytearray(b"".join({
            "valid": VALID,
            "malformed": MALFORMED,
            "merged": MERGED,
            "short-silence": SHORT_SILENCE,
        }[os.environ["UART_FIXTURE"]]))

    def reset_input_buffer(self):
        pass

    def read(self, size=1):
        if not self.buffer:
            return b""
        chunk = bytes(self.buffer[:size])
        del self.buffer[:size]
        return chunk

    def close(self):
        pass
PY

expect_verifier() {
    local name=$1 expected_status=$2 expected_line=$3 readback=$4 uart_fixture=$5
    shift 5
    local stdout stderr status
    stdout=$(mktemp)
    stderr=$(mktemp)
    firmware_source_is_expected && firmware_uart_activity_properties_are_expected && READBACK="$readback" UART_FIXTURE="$uart_fixture" PYTHONPATH="$fixture/modules" \
        bash "$poc/verify-board.sh" "$@" >"$stdout" 2>"$stderr"
    status=$?
    if [ "$status" -ne "$expected_status" ] || ! grep -Fqx -- "$expected_line" "$stdout"; then
        fail "$name"
        printf 'expected status: %s; actual status: %s\n' "$expected_status" "$status" >&2
        printf 'expected stdout line: %s\n' "$expected_line" >&2
    fi
    rm -f "$stdout" "$stderr"
}

expect_verifier \
    matching_readback_and_buffered_uart_activity_pass \
    0 \
    'flash=PASS readback=PASS static=PASS serial=PASS timing=PASS led=PASS' \
    match valid --port fake --led-observed
stdout=$(mktemp)
stderr=$(mktemp)
firmware_source_is_expected && firmware_uart_activity_properties_are_expected && \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.abbrev GIT_CONFIG_VALUE_0=12 READBACK=match UART_FIXTURE=valid PYTHONPATH="$fixture/modules" \
    bash "$poc/verify-board.sh" --port fake --led-observed >"$stdout" 2>"$stderr"
status=$?
if [ "$status" -ne 0 ] || ! grep -Fqx 'flash=PASS readback=PASS static=PASS serial=PASS timing=PASS led=PASS' "$stdout"; then
    fail alternate_core_abbrev_keeps_baseline_fingerprint
fi
rm -f "$stdout" "$stderr"
expect_verifier \
    malformed_buffered_uart_frame_fails \
    1 \
    'serial=FAIL' \
    match malformed --port fake --led-observed
expect_verifier \
    readback_hash_mismatch_fails \
    1 \
    'readback=FAIL' \
    differ valid --port fake --led-observed

expect_static_rejects_mutation() {
    local name=$1 path=$2
    local backup stdout stderr status
    backup=$(mktemp)
    stdout=$(mktemp)
    stderr=$(mktemp)
    cp "$path" "$backup"
    printf '\n// controlled static-check mutation\n' >>"$path"
    READBACK=match UART_FIXTURE=valid PYTHONPATH="$fixture/modules" \
        bash "$poc/verify-board.sh" --port fake --led-observed >"$stdout" 2>"$stderr"
    status=$?
    mv "$backup" "$path"
    if [ "$status" -eq 0 ]; then
        fail "$name"
        printf 'static check accepted controlled mutation: %s\n' "$path" >&2
    fi
    rm -f "$stdout" "$stderr"
}

# Full source hash must reject any new GPIO behavior, not merely changed
# register definitions.
gpio_backup=$(mktemp)
cp "$poc/src/main.rs" "$gpio_backup"
python3 - "$poc/src/main.rs" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
path.write_text(source.replace(
    '        GPIO_ENABLE_W1TS.write_volatile(LED);',
    '        GPIO_ENABLE_W1TS.write_volatile(LED);\n        GPIO_OUT_W1TC.write_volatile(LED);',
))
PY
READBACK=match UART_FIXTURE=valid PYTHONPATH="$fixture/modules" \
    bash "$poc/verify-board.sh" --port fake --led-observed >/dev/null 2>&1
gpio_status=$?
mv "$gpio_backup" "$poc/src/main.rs"
if [ "$gpio_status" -eq 0 ]; then
    fail extra_gpio_write_fails_static_check
fi

expect_static_rejects_mutation arbitrary_compiler_file_mutation_fails_static_check \
    "$root/compiler/rustc_abi/src/lib.rs"

# Bound each negative-path invocation.  A malformed UART stream is a verifier
# failure, not permission for the host gate to hang forever.
expect_bounded_verifier() {
    local name=$1 expected_status=$2 expected_line=$3 readback=$4 uart_fixture=$5
    shift 5
    local stdout stderr status
    stdout=$(mktemp)
    stderr=$(mktemp)
    firmware_source_is_expected && READBACK="$readback" UART_FIXTURE="$uart_fixture" PYTHONPATH="$fixture/modules" \
        python3 - "$stdout" "$stderr" "$poc/verify-board.sh" "$@" <<'PY'
import os
import subprocess
import sys

stdout, stderr, command, *args = sys.argv[1:]
with open(stdout, "wb") as out, open(stderr, "wb") as err:
    try:
        result = subprocess.run(["bash", command, *args], stdout=out, stderr=err, timeout=2)
    except subprocess.TimeoutExpired:
        raise SystemExit(124)
raise SystemExit(result.returncode)
PY
    status=$?
    if [ "$status" -ne "$expected_status" ] || ! grep -Fqx -- "$expected_line" "$stdout"; then
        fail "$name"
        printf 'expected status: %s; actual status: %s\n' "$expected_status" "$status" >&2
        printf 'expected stdout line: %s\n' "$expected_line" >&2
    fi
    rm -f "$stdout" "$stderr"
}

# Deterministic UART framing properties.  Fixtures model wire bytes, not host
# timestamps: 5,760 8N1 bytes are one 500 ms active phase at 115200 baud.
# Together these cover FIFO boundary-safe writes/draining (no tail may leak
# into silence), wrapping-independent 26M phase repetition, and parser input
# fragmentation without hardware timing.
# Exercise same coalesced stream repeatedly.  Each invocation has a two-second
# subprocess bound, so a parser liveness regression cannot stall host gates.
for attempt in 1 2 3; do
    expect_bounded_verifier \
        "merged_complete_activity_frames_are_accepted_attempt_$attempt" \
        0 \
        'flash=PASS readback=PASS static=PASS serial=PASS timing=PASS led=PASS' \
        match merged --port fake --led-observed
done
expect_bounded_verifier \
    malformed_activity_byte_fails_without_hanging \
    1 \
    'serial=FAIL' \
    match malformed --port fake --led-observed
expect_bounded_verifier \
    short_silence_between_activity_frames_fails \
    1 \
    'serial=FAIL' \
    match short-silence --port fake --led-observed

expect_argument_error() {
    local name=$1 expected_line=$2
    shift 2
    local stdout stderr status
    stdout=$(mktemp)
    stderr=$(mktemp)
    bash "$poc/verify-board.sh" "$@" >"$stdout" 2>"$stderr"
    status=$?
    if [ "$status" -ne 2 ] || ! grep -Fqx -- "$expected_line" "$stderr"; then
        fail "$name"
        printf 'expected status: 2; actual status: %s\n' "$status" >&2
        printf 'expected stderr line: %s\n' "$expected_line" >&2
    fi
    rm -f "$stdout" "$stderr"
}

expect_argument_error verify_requires_port '--port is required' --led-observed
expect_argument_error verify_requires_led_observed '--led-observed is required' --port fake

rm -rf "$fixture"
[ "$failures" -eq 0 ]
