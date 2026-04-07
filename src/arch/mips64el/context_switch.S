/*
 * MIPS64EL cooperative context switch.
 * void mips64_switch_context(MipsThreadContext *from, MipsThreadContext *to);
 *   $a0 = pointer to from thread's MipsThreadContext
 *   $a1 = pointer to to thread's MipsThreadContext
 *
 * MipsThreadContext layout (13 x u64 = 104 bytes):
 *    0: s0    8: s1   16: s2   24: s3   32: s4   40: s5   48: s6   56: s7
 *   64: gp   72: fp   80: ra   88: status  96: sp
 */

    .set    noreorder
    .set    mips64r2

    .text
    .globl  mips64_switch_context
    .type   mips64_switch_context, @function
    .balign 16

mips64_switch_context:
    /* Save callee-saved registers to from context ($a0) */
    sd      $s0,  0($a0)
    sd      $s1,  8($a0)
    sd      $s2, 16($a0)
    sd      $s3, 24($a0)
    sd      $s4, 32($a0)
    sd      $s5, 40($a0)
    sd      $s6, 48($a0)
    sd      $s7, 56($a0)
    sd      $gp, 64($a0)
    sd      $fp, 72($a0)
    sd      $ra, 80($a0)
    mfc0    $t0, $12            /* CP0.Status */
    sd      $t0, 88($a0)
    sd      $sp, 96($a0)

    /* Restore callee-saved registers from to context ($a1) */
    ld      $s0,  0($a1)
    ld      $s1,  8($a1)
    ld      $s2, 16($a1)
    ld      $s3, 24($a1)
    ld      $s4, 32($a1)
    ld      $s5, 40($a1)
    ld      $s6, 48($a1)
    ld      $s7, 56($a1)
    ld      $gp, 64($a1)
    ld      $fp, 72($a1)
    ld      $ra, 80($a1)
    ld      $t0, 88($a1)
    mtc0    $t0, $12            /* Restore CP0.Status */
    ehb
    ld      $sp, 96($a1)

    /* Return to new thread (through restored $ra) */
    jr      $ra
    nop

    .size   mips64_switch_context, . - mips64_switch_context
