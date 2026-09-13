ENTRY(_start)

MEMORY
{
  iram (rx)  : ORIGIN = 0x40100000, LENGTH = 0x8000
  dram (rwx) : ORIGIN = 0x3FFE8000, LENGTH = 0x14000
}

SECTIONS
{
  .literal : ALIGN(4)
  {
    *(.literal .literal.*)
    *(.entry.literal)
  } > iram

  .text : ALIGN(4)
  {
    KEEP(*(.entry))
    *(.text .text.*)
  } > iram

  .rodata : ALIGN(4)
  {
    *(.rodata .rodata.*)
  } > dram

  .data : ALIGN(4)
  {
    *(.data .data.*)
    *(.sdata .sdata.*)
  } > dram

  .bss (NOLOAD) : ALIGN(4)
  {
    __bss_start = .;
    *(.bss .bss.*)
    *(.sbss .sbss.*)
    *(COMMON)
    __bss_end = .;
  } > dram
}
