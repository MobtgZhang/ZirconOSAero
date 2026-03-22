/* LoongArch64 入口：QEMU -kernel / 未来 EFI 加载器跳入前必须设置栈指针 $r3（ABI LP64D）。
 * 否则首条使用栈的指令会写到无效地址（如 0xFFFFFFFFFFF8）。 */
.section .text.boot, "ax", @progbits
.global _start
.type _start, @function
.align 4
_start:
	la.local $sp, stack_top
	/* UEFI ZBM：约定 a0 = ZIRCON_LOONGARCH_EFI_MAGIC、a1 = handoff 物理地址时保留并传给 kernel_main */
	li.d $t0, 0x6372697A
	bne $a0, $t0, 1f
	b 2f
1:
	li.d $a0, 0
	li.d $a1, 0
2:
	bl kernel_main
.size _start, .-_start
