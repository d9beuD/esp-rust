#![no_std]
#![no_main]
#![feature(asm_experimental_arch)]

use core::panic::PanicInfo;

const GPIO_OUT_W1TS: *mut u32 = 0x6000_0304 as *mut u32;
const GPIO_OUT_W1TC: *mut u32 = 0x6000_0308 as *mut u32;
const GPIO_ENABLE_W1TS: *mut u32 = 0x6000_0310 as *mut u32;
const IO_MUX_GPIO2: *mut u32 = 0x6000_0838 as *mut u32;
const LED: u32 = 1 << 2;
const IO_MUX_FUNC: u32 = 0b111 << 4;
const GPIO2_FUNC: u32 = 0b000 << 4;
const UART_FIFO: *mut u32 = 0x6000_0000 as *mut u32;
const UART_CLKDIV: *mut u32 = 0x6000_0014 as *mut u32;
const UART_STATUS: *mut u32 = 0x6000_001c as *mut u32;
const UART_TX_FIFO_CAPACITY: u32 = 128;
const UART_CLKDIV_DIVIDER: u32 = 451;
const HALF_PERIOD_CYCLES: u32 = 26_000_000;

static mut ACTIVE_PHASE_START: u32 = 0;

#[panic_handler]
fn panic(_: &PanicInfo<'_>) -> ! {
    loop {}
}

#[unsafe(no_mangle)]
pub extern "C" fn main() -> ! {
    unsafe {
        IO_MUX_GPIO2.write_volatile((IO_MUX_GPIO2.read_volatile() & !IO_MUX_FUNC) | GPIO2_FUNC);
        GPIO_OUT_W1TS.write_volatile(LED);
        GPIO_ENABLE_W1TS.write_volatile(LED);
        UART_CLKDIV.write_volatile(UART_CLKDIV_DIVIDER);
        let mut previous_active = 0;
        let mut previous_silence = 0;
        loop {
            let start = cycle_count();
            ACTIVE_PHASE_START = start;
            if previous_active != 0 {
                uart_frame(previous_active, previous_silence);
            }
            while cycle_count().wrapping_sub(start) < 26_000_000 {
                uart_write(b'U');
            }
            uart_drain();
            previous_active = cycle_count().wrapping_sub(start);
            let silence_start = cycle_count();
            delay();
            previous_silence = cycle_count().wrapping_sub(silence_start);
        }
    }
}

fn uart_frame(active: u32, silence: u32) {
    uart_write(b'F');
    uart_hex(active);
    uart_hex(silence);
    uart_write(b'\n');
}

fn uart_hex(value: u32) {
    for shift in (0..32).step_by(4).rev() {
        let digit = ((value >> shift) & 0xf) as u8;
        uart_write(if digit < 10 { b'0' + digit } else { b'a' + digit - 10 });
    }
}

fn uart_write(byte: u8) {
    unsafe {
        while (UART_STATUS.read_volatile() >> 16) & 0xff >= 128 {}
        let tx_fifo_count = (UART_STATUS.read_volatile() >> 16) & 0xff;
        if !uart_write_permitted(tx_fifo_count, ACTIVE_PHASE_START, cycle_count()) {
            return;
        }
        UART_FIFO.write_volatile(byte as u32);
    }
}

fn uart_write_permitted(tx_fifo_count: u32, start: u32, now: u32) -> bool {
    tx_fifo_count < 128 && now.wrapping_sub(start) < HALF_PERIOD_CYCLES
}

fn uart_drain() {
    unsafe { while (UART_STATUS.read_volatile() >> 16) & 0xff != 0 {} }
}

fn delay() {
    let start = cycle_count();
    while cycle_count().wrapping_sub(start) < HALF_PERIOD_CYCLES {}
}

#[inline]
fn cycle_count() -> u32 {
    let count: u32;
    unsafe {
        core::arch::asm!("rsr.ccount {count}", count = out(reg) count, options(nomem, nostack));
    }
    count
}
