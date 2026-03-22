/* ZirconOS Boot Manager — MBR Linker Script
 *
 * The MBR is loaded by BIOS at 0x7C00, then relocates itself to 0x0600.
 * This linker script sets the origin at 0x7C00 (the initial load address)
 * and produces a flat binary of exactly 512 bytes.
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

    . = 0x7C00 + 510;
    .sig : {
        SHORT(0xAA55)
    }

    /DISCARD/ : {
        *(.eh_frame*)
        *(.comment)
        *(.note*)
        *(.bss)
    }
}
