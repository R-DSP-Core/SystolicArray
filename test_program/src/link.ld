OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
  .text :
  {
    KEEP(*(.text.init))
    *(.text .text.*)
  } > RAM

  .rodata :
  {
    *(.rodata .rodata.*)
  } > RAM

  .data :
  {
    *(.data .data.*)
  } > RAM

  . = ALIGN(4);
  __bss_start = .;
  .bss (NOLOAD) :
  {
    *(.bss .bss.*)
    *(COMMON)
  } > RAM
  . = ALIGN(4);
  __bss_end = .;

  __stack_top = ORIGIN(RAM) + LENGTH(RAM);

  /DISCARD/ :
  {
    *(.comment)
    *(.eh_frame*)
  }
}

ASSERT(__bss_end < (__stack_top - 4096), "program overlaps the 4 KiB stack")
