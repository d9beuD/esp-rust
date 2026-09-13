.section .entry, "ax", @progbits
.literal .Lstack_top, 0x3FFFC000
.literal .Lbss_start, __bss_start
.literal .Lbss_end, __bss_end
.global _start
.type _start, @function

_start:
    l32r a1, .Lstack_top
    l32r a2, .Lbss_start
    l32r a3, .Lbss_end
    movi a4, 0
.Lbss_loop:
    bgeu a2, a3, .Lbss_done
    s32i a4, a2, 0
    addi a2, a2, 4
    j .Lbss_loop
.Lbss_done:
    call0 main
.Lhalt:
    j .Lhalt
