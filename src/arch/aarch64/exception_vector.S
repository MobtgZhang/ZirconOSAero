/* AArch64 EL1 exception vector table.
 * ARM DDI 0487: VBAR_EL1 aligned to 2KiB; 16 entries x 128 bytes each.
 * Layout: 4 exception levels x 4 exception types.
 *
 * TrapFrame layout on stack (36 x u64 = 288 bytes):
 *   0..240  : x0..x30 (31 regs)
 *   248     : SP at exception entry (SP_EL0 or saved stack pointer)
 *   256     : ELR_EL1
 *   264     : SPSR_EL1
 *   272     : ESR_EL1
 *   280     : FAR_EL1
 */

.section .text
.global aarch64_exception_vectors
.type aarch64_exception_vectors, @function

.macro SAVE_REGS
    sub sp, sp, #288
    stp x0,  x1,  [sp, #0]
    stp x2,  x3,  [sp, #16]
    stp x4,  x5,  [sp, #32]
    stp x6,  x7,  [sp, #48]
    stp x8,  x9,  [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30,      [sp, #240]
    /* Save SP (the pre-exception value) */
    add x0, sp, #288
    str x0, [sp, #248]
    /* Save ELR_EL1 and SPSR_EL1 */
    mrs x0, elr_el1
    str x0, [sp, #256]
    mrs x0, spsr_el1
    str x0, [sp, #264]
    /* Save ESR_EL1 and FAR_EL1 */
    mrs x0, esr_el1
    str x0, [sp, #272]
    mrs x0, far_el1
    str x0, [sp, #280]
.endm

.macro RESTORE_REGS
    /* Restore ELR_EL1 and SPSR_EL1 */
    ldr x0, [sp, #256]
    msr elr_el1, x0
    ldr x0, [sp, #264]
    msr spsr_el1, x0
    /* Restore GPRs */
    ldp x0,  x1,  [sp, #0]
    ldp x2,  x3,  [sp, #16]
    ldp x4,  x5,  [sp, #32]
    ldp x6,  x7,  [sp, #48]
    ldp x8,  x9,  [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30,      [sp, #240]
    add sp, sp, #288
.endm

/* Each vector entry must be exactly 128 bytes (32 instructions). */
.macro VECTOR_ENTRY handler
    .balign 128
    SAVE_REGS
    mov x0, sp
    bl \handler
    RESTORE_REGS
    eret
.endm

/* Unused vectors: spin forever. */
.macro VECTOR_ENTRY_UNUSED
    .balign 128
    b .
    .balign 128
.endm

/* ---- Exception vector table ---- */
.balign 2048
aarch64_exception_vectors:
    /* Current EL with SP_EL0 (not used by kernel) */
    VECTOR_ENTRY aarch64_dispatch_sync_el1_sp0    /* +0x000 Synchronous */
    VECTOR_ENTRY aarch64_dispatch_irq_el1         /* +0x080 IRQ */
    VECTOR_ENTRY aarch64_dispatch_fiq_el1         /* +0x100 FIQ */
    VECTOR_ENTRY aarch64_dispatch_serror_el1      /* +0x180 SError */

    /* Current EL with SP_ELx (normal kernel path) */
    VECTOR_ENTRY aarch64_dispatch_sync_el1        /* +0x200 Synchronous */
    VECTOR_ENTRY aarch64_dispatch_irq_el1         /* +0x280 IRQ */
    VECTOR_ENTRY aarch64_dispatch_fiq_el1         /* +0x300 FIQ */
    VECTOR_ENTRY aarch64_dispatch_serror_el1      /* +0x380 SError */

    /* Lower EL using AArch64 (user mode traps) */
    VECTOR_ENTRY aarch64_dispatch_sync_lower      /* +0x400 Synchronous */
    VECTOR_ENTRY aarch64_dispatch_irq_el1         /* +0x480 IRQ */
    VECTOR_ENTRY aarch64_dispatch_fiq_el1         /* +0x500 FIQ */
    VECTOR_ENTRY aarch64_dispatch_serror_el1      /* +0x580 SError */

    /* Lower EL using AArch32 (not supported) */
    VECTOR_ENTRY aarch64_dispatch_sync_lower      /* +0x600 Synchronous */
    VECTOR_ENTRY aarch64_dispatch_irq_el1         /* +0x680 IRQ */
    VECTOR_ENTRY aarch64_dispatch_fiq_el1         /* +0x700 FIQ */
    VECTOR_ENTRY aarch64_dispatch_serror_el1      /* +0x780 SError */

.size aarch64_exception_vectors, .-aarch64_exception_vectors
