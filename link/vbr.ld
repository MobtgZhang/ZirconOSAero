/* ZirconOS Boot Manager — VBR (Volume Boot Record) Linker Script
 *
 * The VBR is loaded by the MBR at 0x7C00 from the start of the
 * active partition. Produces a flat binary of exactly 512 bytes.
 */

OUTPUT_FORMAT(binary)
OUTPUT_ARCH(i386)

SECTIONS
{
    . = 0x7C00;

    .text : {
        *(.text .text.*)
    }

    .data : {
        *(.data .data.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    /* 0xAA55 at sector tail comes from vbr.s (`.org 510` + `.word BOOT_SIG`). */

    /DISCARD/ : {
        *(.eh_frame*)
        *(.comment)
        *(.note*)
        *(.bss)
    }
}
