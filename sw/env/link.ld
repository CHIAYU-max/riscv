/* Tests run from address 0 in the testbench RAM (64 KiB, code and data together). */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x00000000;
  .text.init : { *(.text.init) }
  .text      : { *(.text) }
  . = ALIGN(16);
  .data      : { *(.data) *(.sdata) *(.rodata*) *(.srodata*) }
  .bss       : { *(.bss) *(.sbss) }
  _end = .;
}
