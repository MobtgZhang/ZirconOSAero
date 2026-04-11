/* LoongArch64 入口：QEMU -kernel / 未来 EFI 加载器跳入前必须设置栈指针 $r3（ABI LP64D）。
 * 否则首条使用栈的指令会写到无效地址（如 0xFFFFFFFFFFF8）。 */
.section .text.boot, "ax", @progbits
.global _start
.type _start, @function
.align 4
_start:
	la.local $sp, stack_top
	/*
	 * UEFI ExitBootServices 后：固件常仍置 CRMD.IE、稳定时钟 TCFG.EN、ECFG.IM；EENTRY 亦可能指向已回收的固件向量。
	 * 若首条 IRQ/时钟在 traps.init() 之前命中，取指/仿真路径可触发 QEMU 10.2 LoongArch TCG
	 * `qemu_mutex_lock_iothread_impl: !qemu_mutex_iothread_locked()`（cpus.c）。
	 * 与 `traps.zig` CSR 号一致：CRMD=0x0，ECFG=0x4，EENTRY=0xc，TCFG=0x41。
	 */
	csrrd $t2, 0x0
	li.d $t3, -5
	and $t2, $t2, $t3
	csrwr $t2, 0x0
	csrrd $t2, 0x41
	li.d $t3, -2
	and $t2, $t2, $t3
	csrwr $t2, 0x41
	csrrd $t2, 0x4
	srli.d $t3, $t2, 14
	slli.d $t3, $t3, 14
	csrwr $t3, 0x4
	la.local $t2, loongarch_exc_vectors
	srli.d $t2, $t2, 12
	slli.d $t2, $t2, 12
	csrwr $t2, 0xc
	ibar 0
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
