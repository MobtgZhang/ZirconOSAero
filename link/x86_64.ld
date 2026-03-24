OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

SECTIONS
{
  /* 32MiB：避免 UEFI 在 ~16MiB 附近无法 AllocateAddress（大内核 PT_LOAD 跨区常见失败） */
  . = 0x2000000;

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
  PROVIDE(_kernel_end = .);

  /DISCARD/ :
  {
    *(.eh_frame*)
    *(.comment)
    *(.note*)
  }
}
