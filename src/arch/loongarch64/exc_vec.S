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
	bl loongarch_dispatch_trap
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
