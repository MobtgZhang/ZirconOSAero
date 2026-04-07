/* LoongArch 异常/中断向量区：128 槽 × 512B，与 CSR.ECFG.VS=7 对齐。
 * 入口由 CSR.EENTRY 指向本区基址；ESTAT.EXC×512 为具体槽。见 Linux trap_init / configure_exception_vector。 */
.section .text.loongarch_exc, "ax", @progbits
.balign 65536
.global loongarch_exc_vectors
.type loongarch_exc_vectors, @object
loongarch_exc_vectors:
	.rept 128
	.p2align 9
	addi.d $sp, $sp, -128
	st.d $ra, $sp, 0
	st.d $a0, $sp, 8
	st.d $a1, $sp, 16
	st.d $a2, $sp, 24
	st.d $t0, $sp, 32
	st.d $t1, $sp, 40
	st.d $t2, $sp, 48
	st.d $t3, $sp, 56
	st.d $a7, $sp, 64
	st.d $a3, $sp, 72
	st.d $a4, $sp, 80
	st.d $a5, $sp, 88
	st.d $a6, $sp, 96
	/* a0 = trap frame 指针，供 syscall / 统一分发 */
	move $a0, $sp
	bl loongarch_dispatch_trap
	ld.d $a6, $sp, 96
	ld.d $a5, $sp, 88
	ld.d $a4, $sp, 80
	ld.d $a3, $sp, 72
	ld.d $a7, $sp, 64
	ld.d $t3, $sp, 56
	ld.d $t2, $sp, 48
	ld.d $t1, $sp, 40
	ld.d $t0, $sp, 32
	ld.d $a2, $sp, 24
	ld.d $a1, $sp, 16
	ld.d $a0, $sp, 8
	ld.d $ra, $sp, 0
	addi.d $sp, $sp, 128
	ertn
	.endr
.size loongarch_exc_vectors, .-loongarch_exc_vectors
