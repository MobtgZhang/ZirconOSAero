/* ZirconOS Boot Manager — BIOS Stage2 Linker Script
 *
 * Stage2 runs initially in 16-bit real mode, then transitions to
 * 32-bit protected mode. It is loaded at 0x8000 by the VBR.
 *
 * Memory layout:
 *   0x8000 - 0xFFFF : Stage2 code + data (max 32KB)
 */

OUTPUT_FORMAT(binary)
OUTPUT_ARCH(i386)

SECTIONS
{
    . = 0x8000;

    .text : {
        *(.text .text.*)
    }

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4) {
        *(.data .data.*)
    }

    .bss : ALIGN(4) {
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ : {
        *(.eh_frame*)
        *(.comment)
        *(.note*)
    }
}
