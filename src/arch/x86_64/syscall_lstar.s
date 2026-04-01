# SPDX-License-Identifier: MIT OR Apache-2.0
#
# x86_64 `syscall` 指令入口（IA32_LSTAR）：合成与 `int 0x80` 一致的 InterruptFrame 后走 `isr_common_handler`。
# 约定与 `syscall_entry.s` / `syscall.zig` 一致：RAX=号，RDI/RSI/RDX/R10/R8/R9=参；RCX/R11 由硬件破坏（存用户 RIP/RFLAGS）。
# Ref: Intel SDM Vol.2 SYSCALL/SYSRET; AMD APM Vol.2.

.extern zircon_x86_64_kernel_rsp0
.global syscall_lstar_entry
syscall_lstar_entry:
    movq %rsp, %r12
    movq zircon_x86_64_kernel_rsp0(%rip), %rsp

    pushq $0x23
    pushq %r12
    pushq %r11
    pushq $0x1B
    pushq %rcx

    pushq $0
    pushq $128

    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movq %rsp, %rdi
    call isr_common_handler

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax

    addq $16, %rsp
    iretq
