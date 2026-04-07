/* RISC-V 64 S-mode trap entry/exit.
 * Saves full GPR context + key CSRs onto the kernel stack, calls
 * riscv_dispatch_trap(frame_ptr), then restores and sret.
 *
 * TrapFrame layout (offsets in bytes, 34 x u64 = 272 bytes):
 *   0..248 : x1(ra)..x31  (x0 omitted, always zero)
 *   248    : sepc
 *   256    : sstatus
 *   264    : scause
 */

.section .text
.global riscv_trap_entry
.type riscv_trap_entry, @function
.align 4
riscv_trap_entry:
    addi sp, sp, -272

    sd  x1,    0(sp)
    sd  x3,    8(sp)
    sd  x4,   16(sp)
    sd  x5,   24(sp)
    sd  x6,   32(sp)
    sd  x7,   40(sp)
    sd  x8,   48(sp)
    sd  x9,   56(sp)
    sd x10,   64(sp)
    sd x11,   72(sp)
    sd x12,   80(sp)
    sd x13,   88(sp)
    sd x14,   96(sp)
    sd x15,  104(sp)
    sd x16,  112(sp)
    sd x17,  120(sp)
    sd x18,  128(sp)
    sd x19,  136(sp)
    sd x20,  144(sp)
    sd x21,  152(sp)
    sd x22,  160(sp)
    sd x23,  168(sp)
    sd x24,  176(sp)
    sd x25,  184(sp)
    sd x26,  192(sp)
    sd x27,  200(sp)
    sd x28,  208(sp)
    sd x29,  216(sp)
    sd x30,  224(sp)
    sd x31,  232(sp)

    csrr t0, sepc
    sd   t0, 240(sp)
    csrr t0, sstatus
    sd   t0, 248(sp)
    csrr t0, scause
    sd   t0, 256(sp)

    /* a0 = pointer to TrapFrame on stack */
    mv a0, sp
    call riscv_dispatch_trap

    /* Restore CSRs */
    ld t0, 240(sp)
    csrw sepc, t0
    ld t0, 248(sp)
    csrw sstatus, t0

    /* Restore GPRs */
    ld  x1,    0(sp)
    ld  x3,    8(sp)
    ld  x4,   16(sp)
    ld  x5,   24(sp)
    ld  x6,   32(sp)
    ld  x7,   40(sp)
    ld  x8,   48(sp)
    ld  x9,   56(sp)
    ld x10,   64(sp)
    ld x11,   72(sp)
    ld x12,   80(sp)
    ld x13,   88(sp)
    ld x14,   96(sp)
    ld x15,  104(sp)
    ld x16,  112(sp)
    ld x17,  120(sp)
    ld x18,  128(sp)
    ld x19,  136(sp)
    ld x20,  144(sp)
    ld x21,  152(sp)
    ld x22,  160(sp)
    ld x23,  168(sp)
    ld x24,  176(sp)
    ld x25,  184(sp)
    ld x26,  192(sp)
    ld x27,  200(sp)
    ld x28,  208(sp)
    ld x29,  216(sp)
    ld x30,  224(sp)
    ld x31,  232(sp)

    addi sp, sp, 272
    sret
.size riscv_trap_entry, .-riscv_trap_entry
