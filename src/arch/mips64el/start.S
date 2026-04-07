/*
 * MIPS64EL kernel entry point
 * Target: Loongson 3A1000-3A4000 (MIPS64 Release 2, little-endian)
 *
 * After ZBM UEFI exits boot services, execution jumps here.
 * CPU is in kernel mode (CP0.Status.KSU = 00), 64-bit addressing enabled.
 */

#include "mips_defs.h"

    .set    noreorder
    .set    mips64r2

    .section .text.boot, "ax"
    .globl  _start
    .type   _start, @function
    .balign 16

_start:
    /* Disable interrupts, clear BEV (use RAM vectors), enable 64-bit segments */
    mfc0    $t0, CP0_STATUS
    li      $t1, ~(ST_BEV | ST_IE | ST_ERL | ST_EXL)
    and     $t0, $t0, $t1
    /* KX=1, SX=1, UX=1 for 64-bit kernel/supervisor/user addressing */
    li      $t1, (ST_KX | ST_SX | ST_UX)
    or      $t0, $t0, $t1
    mtc0    $t0, CP0_STATUS
    ehb

    /* Set EBase to point to our exception vectors (physical base, low bits) */
    dla     $t0, _mips_exc_vectors
    /* EBase: WG=1 (bit 11) allows full address write on MIPS64R2+ */
    mfc0    $t1, CP0_EBASE
    li      $t2, 0xFFFFF000
    and     $t1, $t1, $zero
    /* Write exception base (page-aligned) */
    ins     $t1, $t0, 12, 20
    mtc0    $t1, CP0_EBASE
    ehb

    /* Initialize $gp (global pointer for N64 ABI) */
    dla     $gp, _gp

    /* Set up kernel stack */
    dla     $sp, _stack_top

    /* Clear BSS */
    dla     $t0, _bss_start
    dla     $t1, _bss_end
1:
    beq     $t0, $t1, 2f
    nop
    sd      $zero, 0($t0)
    daddiu  $t0, $t0, 8
    b       1b
    nop
2:

    /* Pass arguments to kernel_main(magic, info_addr):
     * $a0 = multiboot magic (0 for direct boot)
     * $a1 = info structure address (0 for direct boot)
     * These may have been set by the bootloader before jumping here.
     * If coming from _start directly, they default to whatever $a0/$a1 hold.
     */
    /* For UEFI handoff path, ZBM sets $a0/$a1 before jumping. */
    /* For -kernel direct boot (QEMU), pass zeros. */
    dla     $t9, kernel_main
    jalr    $t9
    nop

    /* Should not return */
3:
    wait
    b       3b
    nop

    .size   _start, . - _start
