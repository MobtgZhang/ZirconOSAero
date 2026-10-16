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
    .quad uefi_kernel_entry
    .quad stack_top
    .quad 0

.section .text.boot, "ax", @progbits
.global _start
.type _start, @function
.align 4
_start:
    ldr x0, =stack_top
    mov sp, x0
    bl enable_simd_fp
    mov x0, #0
    mov x1, #0
    bl kernel_main
.Lhalt:
    wfi
    b .Lhalt
.size _start, .-_start

/*
 * UEFI 入口包装：ZBM 从 _uefi_vector 读取此地址并跳转。
 * 在进入 Zig kernel_main 之前必须启用 CPACR_EL1 的 FP/SIMD，
 * 否则编译器生成的 fastMemset/fastMemcpy 等 NEON 优化路径
 * 在 EL1 默认 CPACR_EL1=0（FPEN=0b00）时会触发 Illegal Instruction。
 */
.global uefi_kernel_entry
.type uefi_kernel_entry, @function
.align 4
uefi_kernel_entry:
    /* ZBM 已经设置了栈；只需启用 SIMD/FP */
    bl enable_simd_fp
    /* ZBM 传参：x0 = magic, x1 = info_addr（保持不变传给 kernel_main） */
    bl kernel_main
.Luefi_halt:
    wfi
    b .Luefi_halt
.size uefi_kernel_entry, .-uefi_kernel_entry

/*
 * 启用 EL1 的 FP/SIMD 访问（CPACR_EL1.FPEN = 0b11）。
 * 必须在任何可能使用 NEON 寄存器的代码之前执行。
 * 使用 x19 避免与 ZBM 传参寄存器 (x0, x1) 冲突。
 */
.global enable_simd_fp
.type enable_simd_fp, @function
.align 4
enable_simd_fp:
    mrs x9, cpacr_el1
    orr x9, x9, #0x300000     /* FPEN[21:20] = 0b11 */
    msr cpacr_el1, x9
    isb
    ret
.size enable_simd_fp, .-enable_simd_fp
