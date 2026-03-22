/* QEMU virt 首段 RAM: memory@0 为 0 .. 0x10000000（256MB，见 machine dumpdtb）。
 * - 勿使用 0x9000… 内核虚拟高位作 PhysAddr：固件/GRUB 无法映射到真实 RAM。
 * - 勿把内核放在 0x80000000 起的高内存区：QEMU load_elf 对 -kernel 直启时，BSS 若跨
 *   低 256MB 与高内存之间的空洞（0x10000000..0x80000000）会未映射，导致启动即非法写。
 * - 链接在 0x00200000（2MB）：整块映像+BSS 落在首段 RAM 内，便于 -kernel 与将来 EFI 加载器。 */
OUTPUT_FORMAT(elf64-loongarch)
ENTRY(_start)

SECTIONS
{
  . = 0x00200000;
  PROVIDE(_kernel_start = .);

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
    *(COMMON)
    *(.bss .bss.*)
  }

  . = ALIGN(16);
  /* 勿用 PROVIDE：否则符号可能不进 .symtab，测试与调试器看不到 stack_bottom */
  stack_bottom = .;
  /* 1 MiB 内核栈（与 x86_64 start.s 同量级） */
  . += 0x100000;
  stack_top = .;

  . = ALIGN(4K);
  PROVIDE(_kernel_end = .);
}
