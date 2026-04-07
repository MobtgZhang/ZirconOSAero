/* RISC-V 64: kernel entry, BSS clear, stack, UEFI vector table.
 * Two entry scenarios:
 *   1. QEMU -kernel: a0=hartid, a1=DTB/0  (magic will not match MB2)
 *   2. UEFI ZBM:     a0=magic,  a1=mb2_phys (or via _uefi_vector)
 */

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
    .word 0x55454649          /* magic "UEFI" */
    .word 1                   /* version */
    .quad kernel_main
    .quad stack_top
    .quad 0                   /* mb2_phys (written by ZBM) */

.section .text.boot, "ax", @progbits
.global _start
.type _start, @function
.align 4
_start:
    /* Disable S-mode interrupts while initialising */
    csrci sstatus, 0x2

    /* Set stvec to early trap handler (replaced by traps.zig later) */
    la t0, riscv_early_trap_entry
    csrw stvec, t0

    la sp, stack_top

    /* Clear BSS */
    la t0, __bss_start
    la t1, __bss_end
.Lclear_bss:
    bgeu t0, t1, .Lbss_done
    sd zero, 0(t0)
    addi t0, t0, 8
    j .Lclear_bss
.Lbss_done:

    /* Forward a0/a1 to kernel_main(magic, info_addr) unchanged */
    call kernel_main
.Lhalt:
    wfi
    j .Lhalt
.size _start, .-_start

/* Early S-mode trap: print '>' to UART0 then halt — for pre-traps.zig diagnostics */
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
