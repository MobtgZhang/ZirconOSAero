# x86_64 协作式上下文切换。
# 遵循 System V AMD64 ABI，保存 callee-saved 寄存器：rbx, rbp, r12-r15, rsp。
#
# 调用约定：
#   rdi = from* (当前线程上下文)
#   rsi = to*   (目标线程上下文)
#
# X86ThreadContext 布局 (extern struct, 18 * u64 = 144 bytes):
#   offset   0: r15
#   offset   8: r14
#   offset  16: r13
#   offset  24: r12
#   offset  32: rbp
#   offset  40: rbx
#   offset  48: r11
#   offset  56: r10
#   offset  64: r9
#   offset  72: r8
#   offset  80: rax
#   offset  88: rcx
#   offset  96: rdx
#   offset 104: rsi
#   offset 112: rdi
#   offset 120: reserved
#   offset 128: rsp
#   offset 136: rip

.section .text
.global x86_64_switch_context
.type x86_64_switch_context, @function
.align 16
x86_64_switch_context:
    # 保存 callee-saved 寄存器到 from 上下文
    movq %r15, (%rdi)
    movq %r14, 8(%rdi)
    movq %r13, 16(%rdi)
    movq %r12, 24(%rdi)
    movq %rbp, 32(%rdi)
    movq %rbx, 40(%rdi)
    movq %r11, 48(%rdi)
    movq %r10, 56(%rdi)
    movq %r9,  64(%rdi)
    movq %r8,  72(%rdi)
    movq %rax, 80(%rdi)
    movq %rcx, 88(%rdi)
    movq %rdx, 96(%rdi)
    movq %rsi, 104(%rdi)
    movq %rdi, 112(%rdi)

    # reserved 字段保持为 0

    # 保存 rsp（栈指针必须保存以便恢复）
    movq %rsp, 128(%rdi)

    # 从目标线程结构恢复寄存器
    movq 112(%rsi), %rdi
    movq 104(%rsi), %rsi
    movq  96(%rsi), %rdx
    movq  88(%rsi), %rcx
    movq  80(%rsi), %rax
    movq  72(%rsi), %r8
    movq  64(%rsi), %r9
    movq  56(%rsi), %r10
    movq  48(%rsi), %r11
    movq  40(%rsi), %rbx
    movq  32(%rsi), %rbp
    movq  24(%rsi), %r12
    movq  16(%rsi), %r13
    movq   8(%rsi), %r14
    movq   (%rsi), %r15

    # 恢复 rsp
    movq 128(%rsi), %rsp

    # 跳转到目标线程的入口点
    # rip 指向蹦床函数或线程入口
    jmp *136(%rsi)

.size x86_64_switch_context, .-x86_64_switch_context

# 蹦床函数：处理首次切换到新线程。
# 栈顶是要跳转的入口点地址。
# 弹出后直接跳转到入口点。
.global x86_64_thread_trampoline
.type x86_64_thread_trampoline, @function
.align 16
x86_64_thread_trampoline:
    # 栈顶是线程入口点，弹出并跳转
    popq %rax
    jmp *%rax

.size x86_64_thread_trampoline, .-x86_64_thread_trampoline
