# ZirconOSAero — int 0x80 syscall entry (vector 128)
# Same InterruptFrame as syscall_lstar.s / ISR; dispatcher: src/arch/x86_64/syscall.zig
# NT x64 service convention: rax=SSDT index; 1st arg=R10; 2nd=rdx; 3rd=r8; 4th=r9; rest on user stack (+0x28…).

.global syscall_entry
syscall_entry:
    push $0
    push $128

    push %rax
    push %rbx
    push %rcx
    push %rdx
    push %rsi
    push %rdi
    push %rbp
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15

    mov %rsp, %rdi
    call isr_common_handler

    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rbp
    pop %rdi
    pop %rsi
    pop %rdx
    pop %rcx
    pop %rbx
    pop %rax

    add $16, %rsp
    iretq
