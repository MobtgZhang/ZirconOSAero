/* AArch64：栈与 UEFI 向量表（与 boot/zbm/uefi/main.zig 扫描逻辑一致） */
.section .bss
.align 16
.global stack_bottom
stack_bottom:
    .skip 1048576
.global stack_top
stack_top:

/* "aw"：可写，ZBM 在 br 前写入 mb2_phys（Multiboot2 信息块物理地址），避免仅靠 x1 与固件 VA 不一致 */
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
    ldr x0, =stack_top
    mov sp, x0
    mov x0, #0
    mov x1, #0
    bl kernel_main
.Lhalt:
    wfi
    b .Lhalt
.size _start, .-_start
