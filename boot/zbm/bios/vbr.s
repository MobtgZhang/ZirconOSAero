# ============================================================================
# ZirconOS Boot Manager — VBR (Volume Boot Record)
# ============================================================================
#
# Loaded by the MBR at 0x7C00 from the start of the active partition.
# Reads the stage2 boot manager from consecutive sectors on the partition.
#
# Responsibilities:
#   1. Display early boot banner
#   2. Load stage2 (zbmload) from sectors 1..N of the partition
#   3. Transfer control to stage2
#
# Memory layout:
#   0x7C00 - 0x7DFF : This VBR
#   0x8000 - 0xFFFF : Stage2 loaded here (up to 32KB)
#   0x7BFE          : Stack (grows down)
# ============================================================================

.code16
.section .text
.global _vbr_start

.set VBR_ADDR,        0x7C00
.set STAGE2_ADDR,     0x8000
.set STAGE2_SECTORS,  64            # 64 sectors = 32KB max for stage2
.set STACK_TOP,       0x7C00
.set BOOT_SIG,        0xAA55

_vbr_start:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $STACK_TOP, %sp
    sti

    # Save boot drive
    mov %dl, (vbr_boot_drive)
    # SI points to active partition entry (passed by MBR)
    mov %si, (vbr_part_entry)

    # Display VBR banner
    mov $msg_vbr_banner, %si
    call .vbr_print

    # Get partition start LBA from the MBR partition entry
    mov (vbr_part_entry), %si
    movl 8(%si), %eax               # Starting LBA of this partition
    addl $1, %eax                   # Stage2 starts at partition_start + 1
    mov %eax, (vbr_dap_lba_low)

    # Set up DAP to load stage2
    movw $STAGE2_SECTORS, (vbr_dap_count)
    movw $STAGE2_ADDR, (vbr_dap_offset)

    # INT 13h Extended Read
    mov (vbr_boot_drive), %dl
    mov $vbr_dap, %si
    mov $0x42, %ah
    int $0x13
    jc .vbr_disk_error

    # Verify stage2 magic at start
    cmpw $0x5A42, (STAGE2_ADDR)     # 'ZB' magic
    jne .vbr_bad_stage2

    mov $msg_loading, %si
    call .vbr_print

    # Pass boot drive in DL, partition entry in SI
    mov (vbr_boot_drive), %dl
    mov (vbr_part_entry), %si
    jmp STAGE2_ADDR + 2             # Skip magic word, jump to code

.vbr_disk_error:
    mov $msg_vbr_disk_err, %si
    call .vbr_print
    jmp .vbr_halt

.vbr_bad_stage2:
    mov $msg_vbr_bad_s2, %si
    call .vbr_print
    jmp .vbr_halt

.vbr_halt:
    hlt
    jmp .vbr_halt

# ── Print null-terminated string ──
.vbr_print:
    lodsb
    test %al, %al
    jz .vbr_print_done
    mov $0x0E, %ah
    mov $0x07, %bx
    int $0x10
    jmp .vbr_print
.vbr_print_done:
    ret

# ── Data ──
vbr_boot_drive:
    .byte 0x80
vbr_part_entry:
    .word 0

.align 4
vbr_dap:
    .byte 0x10
    .byte 0x00
vbr_dap_count:
    .word 1
vbr_dap_offset:
    .word STAGE2_ADDR
vbr_dap_segment:
    .word 0x0000
vbr_dap_lba_low:
    .long 0
vbr_dap_high:
    .long 0

# ── Messages ──
msg_vbr_banner:
    .asciz "ZirconOS Boot Manager\r\n"
msg_loading:
    .asciz "Loading...\r\n"
msg_vbr_disk_err:
    .asciz "VBR: Disk error\r\n"
msg_vbr_bad_s2:
    .asciz "VBR: Bad stage2\r\n"

# ── Pad to 510 bytes + boot signature ──
.org 510
    .word BOOT_SIG
