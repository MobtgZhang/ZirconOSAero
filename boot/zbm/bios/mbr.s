# ============================================================================
# ZirconOS Boot Manager — MBR Stage 1 (Master Boot Record)
# ============================================================================
#
# This is the first code executed by BIOS on a legacy (MBR) boot.
# Resides in the first 512 bytes of the disk (LBA 0).
#
# Responsibilities:
#   1. Relocate self from 0x7C00 to 0x0600
#   2. Scan the MBR partition table for the active partition
#   3. Load the VBR (Volume Boot Record) of the active partition
#   4. Transfer control to the VBR
#
# Memory layout:
#   0x0600 - 0x07FF : Relocated MBR
#   0x7C00 - 0x7DFF : VBR loaded here
#   0x7E00 - 0x7FFF : Stack
#
# Compatible with both MBR and hybrid GPT protective MBR.
# ============================================================================

.code16
.section .text
.global _mbr_start

.set MBR_LOAD_ADDR,   0x7C00
.set MBR_RELOC_ADDR,  0x0600
.set VBR_LOAD_ADDR,   0x7C00
.set STACK_TOP,       0x7C00
.set PART_TABLE_OFF,  0x01BE
.set PART_ENTRY_SIZE, 16
.set PART_COUNT,      4
.set BOOT_SIG,        0xAA55

_mbr_start:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $STACK_TOP, %sp
    sti

    # ── Relocate MBR from 0x7C00 to 0x0600 ──
    mov $MBR_LOAD_ADDR, %si
    mov $MBR_RELOC_ADDR, %di
    mov $256, %cx                   # 512 bytes = 256 words
    cld
    rep movsw

    # Far jump to relocated code
    ljmp $0x0000, $relocated
relocated:

    # Save boot drive number (BIOS passes in DL)
    mov %dl, (boot_drive)

    # ── Scan partition table for active (bootable) partition ──
    mov $MBR_RELOC_ADDR + PART_TABLE_OFF, %si
    mov $PART_COUNT, %cx

.scan_partitions:
    testb $0x80, (%si)              # Check active flag (bit 7)
    jnz .found_active
    add $PART_ENTRY_SIZE, %si
    loop .scan_partitions

    # No active partition found — try GPT fallback
    jmp .try_gpt_fallback

.found_active:
    mov %si, (active_part_ptr)

    # Read the VBR from the active partition's starting LBA
    # Partition entry offset +8 = LBA start (4 bytes, little-endian)
    movl 8(%si), %eax
    mov %eax, (dap_lba_low)

    # ── Load VBR using INT 13h Extended Read (LBA) ──
    mov (boot_drive), %dl
    mov $dap, %si
    mov $0x42, %ah
    int $0x13
    jc .disk_error

    # Verify VBR boot signature
    cmpw $BOOT_SIG, (VBR_LOAD_ADDR + 510)
    jne .invalid_vbr

    # ── Transfer control to VBR ──
    mov (boot_drive), %dl
    mov (active_part_ptr), %si
    ljmp $0x0000, $VBR_LOAD_ADDR

# ── GPT Protective MBR Fallback ──
# If partition type 0xEE (GPT protective), read LBA 1 for GPT header
# then find the ZirconOS boot partition (GUID-based)
.try_gpt_fallback:
    mov $MBR_RELOC_ADDR + PART_TABLE_OFF, %si
    mov $PART_COUNT, %cx

.scan_gpt:
    cmpb $0xEE, 4(%si)             # Partition type = GPT protective?
    je .load_gpt_stage2
    add $PART_ENTRY_SIZE, %si
    loop .scan_gpt

    # Neither active MBR partition nor GPT found
    mov $msg_no_os, %si
    call .print_string
    jmp .halt

.load_gpt_stage2:
    # GPT disk detected — load stage2 from LBA 2 (after GPT header)
    # Stage2 is stored at a known location (LBA 2, 32 sectors = 16KB)
    movl $2, (dap_lba_low)
    movw $32, (dap_count)           # 32 sectors = 16KB
    movw $0x7E00, (dap_offset)      # Load stage2 after VBR area

    mov (boot_drive), %dl
    mov $dap, %si
    mov $0x42, %ah
    int $0x13
    jc .disk_error

    # Jump to stage2
    mov (boot_drive), %dl
    ljmp $0x0000, $0x7E00

# ── Error Handlers ──
.disk_error:
    mov $msg_disk_err, %si
    call .print_string
    jmp .halt

.invalid_vbr:
    mov $msg_bad_vbr, %si
    call .print_string
    jmp .halt

.halt:
    mov $msg_halt, %si
    call .print_string
.halt_loop:
    hlt
    jmp .halt_loop

# ── Print null-terminated string (SI = string pointer) ──
.print_string:
    lodsb
    test %al, %al
    jz .print_done
    mov $0x0E, %ah
    mov $0x07, %bx
    int $0x10
    jmp .print_string
.print_done:
    ret

# ── Data ──
boot_drive:
    .byte 0x80
active_part_ptr:
    .word 0

# INT 13h Extended Read Disk Address Packet (DAP)
.align 4
dap:
    .byte 0x10                      # DAP size
    .byte 0x00                      # reserved
dap_count:
    .word 1                         # number of sectors
dap_offset:
    .word VBR_LOAD_ADDR             # offset (destination)
dap_segment:
    .word 0x0000                    # segment
dap_lba_low:
    .long 0                         # LBA low 32 bits
dap_lba_high:
    .long 0                         # LBA high 32 bits

# ── Messages ──
msg_disk_err:
    .asciz "ZBM: Disk read error\r\n"
msg_bad_vbr:
    .asciz "ZBM: Invalid VBR\r\n"
msg_no_os:
    .asciz "ZBM: No bootable partition\r\n"
msg_halt:
    .asciz "ZBM: System halted\r\n"

# ── Padding to 446 bytes (before partition table) ──
.org 446
# Partition table (64 bytes) and boot signature filled by disk tool
partition_table:
    .skip 64, 0

boot_signature:
    .word BOOT_SIG
