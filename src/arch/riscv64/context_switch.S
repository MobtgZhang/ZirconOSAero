/* RISC-V 64: cooperative context switch (callee-saved registers + ra + sp).
 * Layout matches RvThreadContext in thread_switch.zig (14 x u64 = 112 bytes). */

.section .text
.global riscv_switch_context
.type riscv_switch_context, @function
.align 4
riscv_switch_context:
    /* a0 = from_ctx*, a1 = to_ctx* */
    sd ra,   0(a0)
    sd sp,   8(a0)
    sd s0,  16(a0)
    sd s1,  24(a0)
    sd s2,  32(a0)
    sd s3,  40(a0)
    sd s4,  48(a0)
    sd s5,  56(a0)
    sd s6,  64(a0)
    sd s7,  72(a0)
    sd s8,  80(a0)
    sd s9,  88(a0)
    sd s10, 96(a0)
    sd s11, 104(a0)

    ld ra,   0(a1)
    ld sp,   8(a1)
    ld s0,  16(a1)
    ld s1,  24(a1)
    ld s2,  32(a1)
    ld s3,  40(a1)
    ld s4,  48(a1)
    ld s5,  56(a1)
    ld s6,  64(a1)
    ld s7,  72(a1)
    ld s8,  80(a1)
    ld s9,  88(a1)
    ld s10, 96(a1)
    ld s11, 104(a1)
    ret
.size riscv_switch_context, .-riscv_switch_context

/* New-thread trampoline: entry address is on top of the stack. */
.global riscv_thread_trampoline
.type riscv_thread_trampoline, @function
.align 4
riscv_thread_trampoline:
    ld t0, 0(sp)
    addi sp, sp, 8
    jr t0
.size riscv_thread_trampoline, .-riscv_thread_trampoline
