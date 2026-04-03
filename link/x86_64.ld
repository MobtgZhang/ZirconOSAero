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

  /* 映像末尾（首字节不属于内核）；见 src/arch/x86_64/kernel_end.s `_kernel_end`。 */
  .kernel_image_end : ALIGN(4K)
  {
    KEEP(*(.kernel_image_end))
  }

  /DISCARD/ :
  {
    *(.eh_frame*)
    *(.comment)
    *(.note*)
  }
}
