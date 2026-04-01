# SPDX-License-Identifier: MIT OR Apache-2.0
#
# x86_64 `syscall` 入口（IA32_LSTAR）：构造与 `int 0x80` 一致的 InterruptFrame 后调用 `isr_common_handler`；
# 返回时使用 **sysretq**（需 GDT 中用户 SS 选择子比用户 CS 小 8，见 `hal/x86_64/gdt.zig`）。
# 约定：RAX=服务号；NT 路径第 1 参在 R10（RCX/R11 由 SYSCALL 破坏）；与 `syscall.zig` 一致。
# Ref: Intel SDM Vol.2 SYSCALL/SYSRET；Vol.4 IA32_STAR

.extern zircon_x86_64_kernel_rsp0
.global syscall_lstar_entry
syscall_lstar_entry:
    movq %rsp, %r12
    movq zircon_x86_64_kernel_rsp0(%rip), %rsp

    pushq $0x1B
    pushq %r12
    pushq %r11
    pushq $0x23
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

    popq %rcx
    addq $8, %rsp
    popq %r11
    popq %rsi
    addq $8, %rsp
    movq %rsi, %rsp
    sysretq
