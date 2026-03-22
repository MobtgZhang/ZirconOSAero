/* RISC-V 64：栈与 UEFI 向量表 */
.section .bss
.align 16
.global stack_bottom
stack_bottom:
    .skip 1048576
.global stack_top
stack_top:

.section .uefi_vector, "a"
.align 8
.global _uefi_vector
_uefi_vector:
    .word 0x55454649
    .word 0
    .quad kernel_main
    .quad stack_top

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
