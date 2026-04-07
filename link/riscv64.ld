OUTPUT_FORMAT(elf64-littleriscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80200000;
  PROVIDE(_kernel_start = .);

  .uefi_vector : ALIGN(8)
  {
    *(.uefi_vector)
  }

  .text : ALIGN(4K)
  {
    *(.text.boot)
    *(.text .text.*)
  }

  .rodata : ALIGN(4K)
  {
    *(.rodata .rodata.*)
  }

  .data : ALIGN(4K)
  {
    *(.data .data.*)
  }

  .bss : ALIGN(4K)
  {
    PROVIDE(__bss_start = .);
    *(COMMON)
    *(.bss .bss.*)
    PROVIDE(__bss_end = .);
  }

  . = ALIGN(4K);
  PROVIDE(_kernel_end = .);
}
