/* LoongArch64 入口：QEMU -kernel / 未来 EFI 加载器跳入前必须设置栈指针 $r3（ABI LP64D）。
 * 否则首条使用栈的指令会写到无效地址（如 0xFFFFFFFFFFF8）。 */
.section .text.boot, "ax", @progbits
.global _start
.type _start, @function
.align 4
_start:
	la.local $sp, stack_top
	/* UEFI：固件可能只保证魔数在 a0 低 32 位；64 位 bne 误判会清空 a1 → handoff 丢失。bstrpick.d = 取低 32 位。 */
	bstrpick.d $t1, $a0, 31, 0
	li.d $t0, 0x6372697A
	bne $t1, $t0, 1f
	bstrpick.d $a0, $a0, 31, 0
	b 2f
1:
	li.d $a0, 0
	li.d $a1, 0
2:
	bl kernel_main
.size _start, .-_start
