/* C programs: 32 KiB RAM at 0 (the Nexys A7 build, MEM_KIB=32; the simulation RAM is 64 KiB).
   The Basys3 build has 8 KiB, so these images do not run there.
   Code, data and stack share it; the stack starts at the top and grows down. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS
{
  .text   : { *(.text.init) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data   : {
    *(.data .data.*)
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
  } > RAM
  .bss    : {
    __bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
