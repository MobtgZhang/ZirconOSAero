OUTPUT_FORMAT(elf64-tradlittlemips)
ENTRY(_start)

SECTIONS
{
  . = 0xFFFFFFFF80100000;
  PROVIDE(_kernel_start = .);

  .text.boot : ALIGN(4K)
  {
    KEEP(*(.text.boot))
  }

  .text : ALIGN(4K)
  {
    *(.text .text.*)
  }

  .rodata : ALIGN(4K)
  {
    *(.rodata .rodata.*)
  }

  .data : ALIGN(4K)
  {
    *(.data .data.*)
    PROVIDE(_gp = ALIGN(16) + 0x7FF0);
  }

  .got : ALIGN(8)
  {
    *(.got .got.*)
  }

  .sbss : ALIGN(4K)
  {
    *(.sbss .sbss.*)
  }

  .bss : ALIGN(4K)
  {
    PROVIDE(_bss_start = .);
    *(COMMON)
    *(.bss .bss.*)
    PROVIDE(_bss_end = .);
  }

  . = ALIGN(4K);

  PROVIDE(_stack_bottom = .);
  . += 64K;
  PROVIDE(_stack_top = .);

  . = ALIGN(4K);
  PROVIDE(_kernel_end = .);

  /DISCARD/ :
  {
    *(.comment)
    *(.note.*)
    *(.eh_frame*)
  }
}
