# ZirconOS x86_64 ISR stubs with full register save/restore
# Each stub pushes a fake error code (if needed) and the vector number,
# then jumps to the common handler which saves all GP registers.

.macro ISR_NOERR vec
.global isr_stub_\vec
isr_stub_\vec:
    push $0
    push $\vec
    jmp isr_common
.endm

.macro ISR_ERR vec
.global isr_stub_\vec
isr_stub_\vec:
    push $\vec
    jmp isr_common
.endm

# Exceptions 0-31
ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_NOERR 29
ISR_NOERR 30
ISR_NOERR 31

# IRQs 32-47
ISR_NOERR 32
ISR_NOERR 33
ISR_NOERR 34
ISR_NOERR 35
ISR_NOERR 36
ISR_NOERR 37
ISR_NOERR 38
ISR_NOERR 39
ISR_NOERR 40
ISR_NOERR 41
ISR_NOERR 42
ISR_NOERR 43
ISR_NOERR 44
ISR_NOERR 45
ISR_NOERR 46
ISR_NOERR 47

# Default stub for remaining vectors
.global isr_stub_default
isr_stub_default:
    push $0
    push $255
    jmp isr_common

# ISR address lookup table
.section .rodata
.global isr_table
.global isr_default_entry
isr_table:
    .quad isr_stub_0,  isr_stub_1,  isr_stub_2,  isr_stub_3
    .quad isr_stub_4,  isr_stub_5,  isr_stub_6,  isr_stub_7
    .quad isr_stub_8,  isr_stub_9,  isr_stub_10, isr_stub_11
    .quad isr_stub_12, isr_stub_13, isr_stub_14, isr_stub_15
    .quad isr_stub_16, isr_stub_17, isr_stub_18, isr_stub_19
    .quad isr_stub_20, isr_stub_21, isr_stub_22, isr_stub_23
    .quad isr_stub_24, isr_stub_25, isr_stub_26, isr_stub_27
    .quad isr_stub_28, isr_stub_29, isr_stub_30, isr_stub_31
    .quad isr_stub_32, isr_stub_33, isr_stub_34, isr_stub_35
    .quad isr_stub_36, isr_stub_37, isr_stub_38, isr_stub_39
    .quad isr_stub_40, isr_stub_41, isr_stub_42, isr_stub_43
    .quad isr_stub_44, isr_stub_45, isr_stub_46, isr_stub_47
isr_default_entry:
    .quad isr_stub_default

# ── Common ISR handler ──
# Saves all GP registers, calls C handler, restores and returns via iretq.
# Stack layout at handler call:
#   RSP+0:   r15   RSP+8:   r14   RSP+16:  r13   RSP+24:  r12
#   RSP+32:  r11   RSP+40:  r10   RSP+48:  r9    RSP+56:  r8
#   RSP+64:  rbp   RSP+72:  rdi   RSP+80:  rsi   RSP+88:  rdx
#   RSP+96:  rcx   RSP+104: rbx   RSP+112: rax
#   RSP+120: vector  RSP+128: error_code
#   RSP+136: rip   RSP+144: cs    RSP+152: rflags
#   RSP+160: rsp   RSP+168: ss
.section .text
.global isr_common
isr_common:
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

# load_idt(desc_ptr): loads the IDT register
.global load_idt
load_idt:
    lidt (%rdi)
    ret
