/* RISC-V 64：栈与 UEFI 向量表 */
.section .bss
.align 16
.global stack_bottom
stack_bottom:
    .skip 1048576
.global stack_top
stack_top:

.section .uefi_vector, "aw", @progbits
.align 8
.global _uefi_vector
_uefi_vector:
    .word 0x55454649
    .word 1
    .quad kernel_main
    .quad stack_top
    .quad 0

.section .text.boot, "ax", @progbits
.global _start
.type _start, @function
.align 4
_start:
    la sp, stack_top
    li a0, 0
    li a1, 0
    call kernel_main
.Lhalt:
    wfi
    j .Lhalt
.size _start, .-_start

/* 早期 S 态异常：向 UART0 打一字节后 wfi，便于 UEFI 退出后缺 SBI 时仍能看到 fault 痕迹 */
.section .text.trap_early, "ax", @progbits
.align 4
.global riscv_early_trap_entry
riscv_early_trap_entry:
    li t0, 0x10000000
0:
    lbu t1, 5(t0)
    andi t1, t1, 0x20
    beqz t1, 0b
    li t2, '>'
    sb t2, 0(t0)
1:
    wfi
    j 1b
