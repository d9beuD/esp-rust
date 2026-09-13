//@ add-minicore
//@ assembly-output: emit-asm
//@ compile-flags: --target xtensa-esp8266-none-elf -Copt-level=0 -Zmerge-functions=disabled
//@ min-llvm-version: 22
//@ needs-llvm-components: xtensa

#![feature(no_core, lang_items, rustc_attrs, asm_experimental_arch)]
#![crate_type = "rlib"]
#![no_core]

extern crate minicore;
use minicore::*;

extern "C" {
    fn clobber_registers();
}

// A6 is caller-saved under the ESP8266 CALL0 ABI. Keep a live value in A6
// across a call so register allocation must spill and restore it correctly.
// CHECK-LABEL: a6_spill_across_call:
// CHECK: s32i{{(\.n)?}} a6, a1, [[SLOT:[0-9]*[048]]]
// LX106 lowers an out-of-range CALL0 target through A8. A direct CALL form is
// also valid when the target is in range.
// CHECK: {{(callx0 a8|call[0-9]* clobber_registers)}}
// CHECK: l32i{{(\.n)?}} a2, a1, [[SLOT]]
#[no_mangle]
pub unsafe extern "C" fn a6_spill_across_call(mut value: i32) -> i32 {
    asm!("or a6, a6, a6", inout("a6") value, options(nostack));
    clobber_registers();
    value
}
