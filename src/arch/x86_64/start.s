# ZirconOS x86_64 Boot Trampoline
# GRUB Multiboot2 enters in 32-bit protected mode.
# This code sets up long mode page tables and transitions to 64-bit kernel.

.set KERNEL_CS64, 0x08
.set KERNEL_DS64, 0x10

# ── Multiboot2 Header (must be within first 32KB of the image) ──
.section .multiboot2, "a"
.align 8
multiboot2_header:
    .long 0xE85250D6          # magic
    .long 0                   # architecture: i386 (0)
    .long multiboot2_header_end - multiboot2_header  # header_length
    .long -(0xE85250D6 + 0 + (multiboot2_header_end - multiboot2_header))  # checksum

    # Framebuffer request: 1024x768 graphics, 32bpp
    .short 5                  # type = MULTIBOOT_HEADER_TAG_FRAMEBUFFER
    .short 1                  # flags = 1 (optional, boot even if unavailable)
    .long  20                 # size = 20 bytes
    .long  1024               # width
    .long  768                # height
    .long  32                 # depth = 32bpp (graphics mode)

    .align 8
    # end tag
    .short 0                  # type = 0
    .short 0                  # flags = 0
    .long  8                  # size = 8
multiboot2_header_end:

# ── UEFI Boot Vector Table ──
# Provides kernel_main and stack_top addresses for the UEFI boot path.
# Magic "UEFI" (0x55454649) marks this table for discovery by the UEFI loader.
.section .uefi_vector, "a"
.align 8
_uefi_vector:
    .long 0x55454649
    .long 0x00000000
    .quad kernel_main
    .quad stack_top

# ── BSS: Page tables and kernel stack ──
.section .bss
.align 4096
boot_pml4:
    .skip 4096
boot_pdpt:
    .skip 4096
boot_pd:
    .skip 16384               # 4 pages: 4 PDs for 0-4GB identity map

.align 16
.global stack_bottom
stack_bottom:
    .skip 1048576
.global stack_top
stack_top:

# ── Boot GDT for long mode transition ──
.section .rodata
.align 16
boot_gdt:
    .quad 0x0000000000000000   # 0x00: null
    .quad 0x00AF9A000000FFFF   # 0x08: 64-bit kernel code
    .quad 0x00CF92000000FFFF   # 0x10: kernel data
boot_gdt_end:

.align 4
boot_gdt_desc:
    .word boot_gdt_end - boot_gdt - 1
    .long boot_gdt

# ── 32-bit entry point ──
.section .text
.code32
.global _start
_start:
    cli

    # Save multiboot2 magic and info pointer
    mov %eax, %edi
    mov %ebx, %esi

    # Set up page tables: identity-map first 4GB using 2MB pages
    # PML4[0] -> PDPT
    lea boot_pdpt, %eax
    or  $0x03, %eax
    mov %eax, boot_pml4

    # PDPT[0..3] -> boot_pd[0..3] (4 page directories for 4GB)
    lea boot_pd, %eax
    or  $0x03, %eax
    mov %eax, boot_pdpt

    lea boot_pd + 4096, %eax
    or  $0x03, %eax
    mov %eax, boot_pdpt + 8

    lea boot_pd + 8192, %eax
    or  $0x03, %eax
    mov %eax, boot_pdpt + 16

    lea boot_pd + 12288, %eax
    or  $0x03, %eax
    mov %eax, boot_pdpt + 24

    # PD[0..2047] -> 0..4GB (2MB pages, Present+Writable+LargePage)
    lea boot_pd, %eax
    mov $0, %ecx
    mov $2048, %edx
.fill_pd:
    mov %ecx, %ebx
    or  $0x83, %ebx
    mov %ebx, (%eax)
    movl $0, 4(%eax)
    add $0x200000, %ecx
    add $8, %eax
    dec %edx
    jnz .fill_pd

    # Load PML4 into CR3
    lea boot_pml4, %eax
    mov %eax, %cr3

    # Enable PAE (CR4 bit 5)
    mov %cr4, %eax
    or  $(1 << 5), %eax
    mov %eax, %cr4

    # Enable Long Mode (IA32_EFER MSR bit 8)
    mov $0xC0000080, %ecx
    rdmsr
    or  $(1 << 8), %eax
    wrmsr

    # Enable Paging (CR0 bit 31)
    mov %cr0, %eax
    or  $(1 << 31), %eax
    mov %eax, %cr0

    # Load boot GDT
    lgdt boot_gdt_desc

    # Far jump to 64-bit code
    ljmp $KERNEL_CS64, $_start64

# ── 64-bit entry point ──
.code64
_start64:
    # Set up data segments
    mov $KERNEL_DS64, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss

    # Set up kernel stack
    lea stack_top(%rip), %rsp
    xor %rbp, %rbp

    # Enable SSE (Zig compiler emits SSE instructions)
    mov %cr0, %rax
    and $~(1 << 2), %rax   # Clear CR0.EM (x87 emulation)
    or $(1 << 1), %rax      # Set CR0.MP (monitor coprocessor)
    mov %rax, %cr0

    mov %cr4, %rax
    or $(3 << 9), %rax       # Set CR4.OSFXSR (bit 9) + CR4.OSXMMEXCPT (bit 10)
    mov %rax, %cr4

    # edi = multiboot magic, esi = multiboot info (preserved from 32-bit)
    # Zero-extend to 64-bit
    mov %edi, %edi
    mov %esi, %esi

    call kernel_main

1:
    hlt
    jmp 1b

# ── GDT/TSS helper functions (called from Zig) ──
.global load_gdt_flush
load_gdt_flush:
    lgdt (%rdi)
    pushq $0x08
    leaq 1f(%rip), %rax
    pushq %rax
    lretq
1:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    ret

.global load_tss_reg
load_tss_reg:
    ltr %di
    ret
