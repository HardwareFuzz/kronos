/* Minimal linker script for unified IMEM/DMEM in Verilator top
   Memory size matches kronos_compliance_top generic_spram default (8KB) */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
  ram (rwx) : ORIGIN = 0x00000000, LENGTH = 0x00002000
}

SECTIONS
{
  .text ORIGIN(ram) : ALIGN(4)
  {
    *(.text.init)
    *(.init)
    *(.text*)
    *(.rodata*)
  } > ram

  .data : ALIGN(4)
  {
    PROVIDE(_sdata = .);
    *(.data*)
    . = ALIGN(4);
    PROVIDE(_edata = .);
  } > ram

  .tohost : ALIGN(64)
  {
    *(.tohost)
  } > ram

  .bss (NOLOAD) : ALIGN(4)
  {
    PROVIDE(_sbss = .);
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    PROVIDE(_ebss = .);
  } > ram

  /* Stack Pointer at end of RAM */
  PROVIDE(_stack_pointer = ORIGIN(ram) + LENGTH(ram));
}

