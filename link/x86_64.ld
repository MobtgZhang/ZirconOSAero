OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

SECTIONS
{
  . = 1M;

  .multiboot2 : ALIGN(8)
  {
    *(.multiboot2)
  }

  .uefi_vector : ALIGN(8)
  {
    *(.uefi_vector)
  }

  .text : ALIGN(4K)
  {
    *(.text .text.*)
  }

  .rodata : ALIGN(4K)
  {
    *(.rodata .rodata.* .rodata.cst .rodata.str)
  }

  .data : ALIGN(4K)
  {
    *(.data .data.* .data.rel.ro .got .got.plt)
  }

  .bss : ALIGN(4K)
  {
    *(COMMON)
    *(.bss .bss.*)
  }

  . = ALIGN(4K);

  /DISCARD/ :
  {
    *(.eh_frame*)
    *(.comment)
    *(.note*)
  }
}
