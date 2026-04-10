/* RISC-V64 AP (Application Processor) Entry
 * This code is placed in a low-address identity-mapped region (see boot_generic.zig).
 * OpenSBI harts_start brings APs here with:
 *   pc = hart_start argument (this entry address)
 *   a0 = hartid
 *   a1 = 0 (no DTB for secondary harts)
 *
 * We perform minimal bootstrap then jump to riscv_ap_init() Zig code.
 */
    .section .text.ap_entry, "ax", @progbits
    .globl riscv_ap_entry
    .type riscv_ap_entry, @function
    .align 4
riscv_ap_entry:
    /* Disable S-mode interrupts */
    csrci sstatus, 0x2

    /* Load stack pointer from global variable (set by BSP) */
    la      t0, riscv_ap_stack_top
    ld      sp, 0(t0)

    /* Load kernel page table root from global variable */
    la      t0, riscv_ap_satp
    ld      t1, 0(t0)
    beqz    t1, .Lno_paging

    /* Enable Sv39 paging — write SATP and fence */
    csrw    satp, t1
    sfence.vma zero, zero
.Lno_paging:

    /* Set stvec to early trap handler */
    la      t0, riscv_early_trap_entry
    csrw    stvec, t0

    /* Call riscv_ap_init() — never returns */
    call    riscv_ap_init

.Lhang:
    wfi
    j       .Lhang
.size riscv_ap_entry, .-riscv_ap_entry

/* Per-hart global variables (written by BSP, read by each AP)
 * These live in .bss and must be in a low 2GiB identity-mapped region.
 */
    .section .bss.ap_smp, "aw", @nobits
    .align 8
riscv_ap_stack_top:
    .quad   0
riscv_ap_satp:
    .quad   0
