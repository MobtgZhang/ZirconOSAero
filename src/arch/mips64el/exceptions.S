/*
 * MIPS64EL exception vectors — short stubs at fixed EBase offsets jump to
 * mips_exc_enter_kernel_stack (full SAVE_ALL / dispatch / RESTORE).
 * Large handlers in the vector page made .org overflow past 0x80.
 */

#include "mips_defs.h"

    .set    noreorder
    .set    mips64r2

.macro SAVE_ALL_REGS
    sd      $zero, TF_ZERO($sp)
    sd      $at,   TF_AT($sp)
    sd      $v0,   TF_V0($sp)
    sd      $v1,   TF_V1($sp)
    sd      $a0,   TF_A0($sp)
    sd      $a1,   TF_A1($sp)
    sd      $a2,   TF_A2($sp)
    sd      $a3,   TF_A3($sp)
    sd      $a4,   TF_A4($sp)
    sd      $a5,   TF_A5($sp)
    sd      $a6,   TF_A6($sp)
    sd      $a7,   TF_A7($sp)
    sd      $t0,   TF_T0($sp)
    sd      $t1,   TF_T1($sp)
    sd      $t2,   TF_T2($sp)
    sd      $t3,   TF_T3($sp)
    sd      $s0,   TF_S0($sp)
    sd      $s1,   TF_S1($sp)
    sd      $s2,   TF_S2($sp)
    sd      $s3,   TF_S3($sp)
    sd      $s4,   TF_S4($sp)
    sd      $s5,   TF_S5($sp)
    sd      $s6,   TF_S6($sp)
    sd      $s7,   TF_S7($sp)
    sd      $t8,   TF_T8($sp)
    sd      $t9,   TF_T9($sp)
    sd      $k0,   TF_K0($sp)
    sd      $k1,   TF_K1($sp)
    sd      $gp,   TF_GP($sp)
    sd      $k0,   TF_SP($sp)
    sd      $fp,   TF_FP($sp)
    sd      $ra,   TF_RA($sp)
    mfc0    $k0, CP0_STATUS
    sd      $k0,   TF_STATUS($sp)
    mfc0    $k0, CP0_CAUSE
    sd      $k0,   TF_CAUSE($sp)
    dmfc0   $k0, CP0_EPC
    sd      $k0,   TF_EPC($sp)
    dmfc0   $k0, CP0_BADVADDR
    sd      $k0,   TF_BADVADDR($sp)
    mfhi    $k0
    sd      $k0,   TF_HI($sp)
    mflo    $k0
    sd      $k0,   TF_LO($sp)
.endm

.macro RESTORE_ALL_REGS
    ld      $k0,   TF_LO($sp)
    mtlo    $k0
    ld      $k0,   TF_HI($sp)
    mthi    $k0
    ld      $k0,   TF_EPC($sp)
    dmtc0   $k0, CP0_EPC
    ld      $k0,   TF_STATUS($sp)
    mtc0    $k0, CP0_STATUS
    ehb
    ld      $at,   TF_AT($sp)
    ld      $v0,   TF_V0($sp)
    ld      $v1,   TF_V1($sp)
    ld      $a0,   TF_A0($sp)
    ld      $a1,   TF_A1($sp)
    ld      $a2,   TF_A2($sp)
    ld      $a3,   TF_A3($sp)
    ld      $a4,   TF_A4($sp)
    ld      $a5,   TF_A5($sp)
    ld      $a6,   TF_A6($sp)
    ld      $a7,   TF_A7($sp)
    ld      $t0,   TF_T0($sp)
    ld      $t1,   TF_T1($sp)
    ld      $t2,   TF_T2($sp)
    ld      $t3,   TF_T3($sp)
    ld      $s0,   TF_S0($sp)
    ld      $s1,   TF_S1($sp)
    ld      $s2,   TF_S2($sp)
    ld      $s3,   TF_S3($sp)
    ld      $s4,   TF_S4($sp)
    ld      $s5,   TF_S5($sp)
    ld      $s6,   TF_S6($sp)
    ld      $s7,   TF_S7($sp)
    ld      $t8,   TF_T8($sp)
    ld      $t9,   TF_T9($sp)
    ld      $gp,   TF_GP($sp)
    ld      $fp,   TF_FP($sp)
    ld      $ra,   TF_RA($sp)
    ld      $sp,   TF_SP($sp)
.endm

    .section .text.boot, "ax"
    .globl  _mips_exc_vectors
    .balign 4096
_mips_exc_vectors:

    .org    _mips_exc_vectors + 0x000
    .globl  _mips_tlb_refill_vector
_mips_tlb_refill_vector:
    /* Read BadVAddr before touching any register */
    dmfc0   $k1, CP0_BADVADDR
    ehb
    /* Save original sp to k0, switch to kernel stack */
    move    $k0, $sp
    dla     $sp, _stack_top
    daddiu  $sp, $sp, -32
    /* Call Zig fast-path: a0 = BadVAddr; returns 1 on success, 0 on fail */
    move    $a0, $k1
    dla     $t9, mips_tlb_refill_fastpath
    jalr    $t9
    nop
    /* Check return value in $v0 */
    bnez    $v0, 1f
    nop
    /* Fast-path failed — fall through to full trap handler */
    move    $sp, $k0
    move    $k0, $sp
    dla     $at, mips_exc_enter_kernel_stack
    jr      $at
    nop
1:
    /* Success — restore sp and eret */
    move    $sp, $k0
    eret

    .org    _mips_exc_vectors + 0x080
    .globl  _mips_xtlb_refill_vector
_mips_xtlb_refill_vector:
    dmfc0   $k1, CP0_BADVADDR
    ehb
    move    $k0, $sp
    dla     $sp, _stack_top
    daddiu  $sp, $sp, -32
    move    $a0, $k1
    dla     $t9, mips_tlb_refill_fastpath
    jalr    $t9
    nop
    bnez    $v0, 1f
    nop
    move    $sp, $k0
    move    $k0, $sp
    dla     $at, mips_exc_enter_kernel_stack
    jr      $at
    nop
1:
    move    $sp, $k0
    eret

    .org    _mips_exc_vectors + 0x100
    .globl  _mips_cache_error_vector
_mips_cache_error_vector:
    wait
    b       _mips_cache_error_vector
    nop

    .org    _mips_exc_vectors + 0x180
    .globl  _mips_general_exception_vector
_mips_general_exception_vector:
    move    $k0, $sp
    dla     $at, mips_exc_enter_kernel_stack
    jr      $at
    nop

    .org    _mips_exc_vectors + 0x200
    .globl  _mips_interrupt_vector
_mips_interrupt_vector:
    move    $k0, $sp
    dla     $at, mips_exc_enter_kernel_stack
    jr      $at
    nop

    /* Common path (outside fixed vector slots) */
    .globl  mips_exc_enter_kernel_stack
mips_exc_enter_kernel_stack:
    dla     $k1, _stack_top
    daddiu  $sp, $k1, -TF_SIZE
    SAVE_ALL_REGS
    move    $a0, $sp
    dla     $t9, mips_dispatch_trap
    jalr    $t9
    nop
    RESTORE_ALL_REGS
    eret
