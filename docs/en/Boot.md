# ZirconOS boot flow

## 1. Boot paths

ZirconOS supports three boot paths across BIOS and UEFI:

| Path | Firmware | Loader | Flow |
|------|----------|--------|------|
| GRUB BIOS | BIOS | GRUB | BIOS → GRUB → Multiboot2 → kernel.elf |
| GRUB UEFI | UEFI | GRUB | UEFI → GRUB → Multiboot2 → kernel.elf |
| ZBM BIOS | BIOS | ZBM | BIOS → MBR → VBR → Stage2 → kernel.elf |
| ZBM UEFI | UEFI | ZBM | UEFI → ESP → zbmfw.efi → kernel.elf |

## 2. GRUB

### BIOS

1. BIOS loads the GRUB boot sector  
2. GRUB reads `boot/grub/grub.cfg`  
3. Loads `kernel.elf` via Multiboot2  
4. Jumps to `_start`  

### UEFI

1. Firmware loads the GRUB EFI app  
2. GRUB reads config and loads `kernel.elf`  
3. Multiboot2 handoff to the kernel  

### Configuration

- `boot/grub/grub.cfg` — template with `@VERSION@`, `@RESOLUTION@`  
- `boot/grub/grub-full.cfg` — full multi-theme menu  
- `scripts/gen_grub_cfg.py` — generates final config from `build.conf` `GRUB_MENU`  

Menu modes:

- `minimal` — ZirconOS entry only  
- `all` — full menu with all desktop themes  

## 3. ZBM (ZirconOS Boot Manager)

In-tree boot manager for BIOS and UEFI.

### BIOS chain

```
BIOS
  → MBR (boot/zbm/bios/mbr.s)
    scan partition table, load VBR
  → VBR (boot/zbm/bios/vbr.s)
    load Stage2
  → Stage2 (boot/zbm/bios/stage2.s)
    enable A20
    E820 memory map
    VGA text menu
    protected mode
    load kernel.elf
    build Multiboot2 info
    jump to kernel entry
```

### UEFI chain

```
UEFI firmware
  → zbmfw.efi (boot/zbm/uefi/main.zig)
    read config and kernel
    show boot menu
    exit Boot Services
    jump to kernel entry
```

### Core (`boot/zbm/zbm.zig`)

- BCD (boot configuration data)  
- Disk/partition detection  
- Boot menu UI  
- Kernel load and jump  

## 4. x86_64 early start (`start.s`)

Common entry after any loader.

### 32-bit stage

```
_start (32-bit protected mode)
  → save Multiboot2 magic and info pointer
  → build 4GB identity page tables (PML4/PDPT/PD)
  → enable PAE (CR4.PAE)
  → set IA32_EFER.LME for long mode
  → enable paging (CR0.PG)
  → load 64-bit GDT
  → far jump to 64-bit mode
```

### 64-bit stage

```
_start64
  → segment registers
  → kernel stack (stack_top, 16KB)
  → enable SSE (CR0/CR4)
  → call kernel_main(magic, info_addr)
```

## 5. Kernel init phases (Phase 0–12)

`kernel_main` in `src/main.zig` runs phased init.

### Phase 0 — Configuration

- Load embedded configs (`src/config/system.conf`, `boot.conf`, `desktop.conf`)  
- Parse parameters  

### Phase 1 — Core hardware

- Validate Multiboot2 magic  
- GDT/TSS  
- Physical frame allocator (from Multiboot2 mmap)  
- Kernel heap (512KB bump allocator)  

### Phase 2 — Interrupts and scheduling

- IDT (256 vectors)  
- PIC + PIT (~100 Hz)  
- Scheduler  
- Keyboard/mouse drivers  
- `sti`  

### Phase 3 — Virtual memory

- Kernel page tables  
- Identity mapping  
- Map framebuffer  
- Switch page tables  

### Phase 4 — Kernel managers

- Object Manager  
- Security (system token)  
- I/O Manager  

### Phase 5 — IPC and services

- LPC ports: `\LPC\PsServer`, `\LPC\ObServer`, `\LPC\IoServer`  
- Process Server (PID 1)  
- Session Manager / SMSS (PID 2)  

### Phase 6 — Drivers and filesystems

- Video/audio/input drivers  
- VFS  
- FAT32 (`C:\`)  
- NTFS (`D:\`)  
- Registry  

### Phase 7 — Loaders

- PE32/PE32+ loader  
- ELF loader  
- DLL manager  

### Phase 8 — Userland base

- ntdll  
- kernel32  
- Console runtime  
- CMD  
- PowerShell  

### Phase 9 — Win32 subsystem

- csrss  
- Win32 execution engine  

### Phase 10 — Graphics

- user32  
- gdi32  
- GUI dispatch  

### Phase 11 — Extensions

- WOW64  
- AC97 audio driver  

### Phase 12 — Display mode

| Mode | Description |
|------|-------------|
| Desktop | Graphical desktop (theme → DWM) |
| CMD | CMD text UI |
| Text | Raw VGA text |

## 6. Linker scripts

Per-architecture layout:

| File | Arch | Load address |
|------|------|----------------|
| `link/x86_64.ld` | x86_64 | 1MB (0x100000), includes `.multiboot2`, `.uefi_vector` |
| `link/aarch64.ld` | AArch64 | 0x40080000 |
| `link/loongarch64.ld` | LoongArch64 | from `0x00200000` (QEMU virt first RAM; see §8) |
| `link/riscv64.ld` | RISC-V 64 | arch-specific |
| `link/mips64el.ld` | MIPS64 LE | arch-specific |
| `link/mbr.ld` | x86 | MBR at 0x7C00 |
| `link/vbr.ld` | x86 | VBR |
| `link/zbm_bios.ld` | x86 | ZBM BIOS Stage2 |

## 7. Multiboot2 info

Parsed in `src/arch/x86_64/boot.zig`:

| Tag | Use |
|-----|-----|
| Memory map | Physical layout → frame allocator |
| Command line | Boot mode (cmd/powershell/desktop), theme |
| Framebuffer | Address, resolution, depth |
| Boot loader name | Loader identification |

Kernel command-line examples:

- `mode=cmd` — CMD  
- `mode=powershell` — PowerShell  
- `mode=desktop` — desktop  
- `desktop=aero` / `theme=aero` — Aero shell（非 `none` 时等价于 Aero）  

## 8. LoongArch64 boot (QEMU)

### 8.1 Recommended: QEMU `-kernel` (default)

- QEMU `virt` first RAM segment is **0 .. 0x10000000 (256MB)**. The kernel is linked at **`0x00200000`** in `link/loongarch64.ld` so the image (including large `.bss`) fits in that segment. **Do not** place the kernel at **0x80000000**: there is a **hole** between low 256MB and high memory (`VIRT_HIGHMEM_BASE`); BSS spanning the hole causes unmapped writes at boot.  
- Entry **`crt0.S`** must set the **stack pointer** before `kernel_main` (LoongArch LP64D uses `$r3` for stack).  
- **`make run-loongarch64`** with `LOONGARCH64_QEMU_MODE=kernel` uses **`qemu-system-loongarch64 -kernel build/tmp/kernel.elf`** — no EDK2/GRUB/ESP; **serial** `-serial stdio` shows `klog`.  

### 8.2 UEFI + ESP (ZBM only)

This repo has **no GRUB path on LoongArch64**; UEFI boot is **ZBM + UEFI** only (`BOOTLOADER=zbm`; Makefile errors on `grub`).

- Firmware looks for `\EFI\BOOT\BOOTLOONGARCH64.EFI`; missing → Shell.  
- EDK2 Shell (`make fetch-firmware` / `fetch-loongarch-boot-efi`) is auxiliary, not the primary path.  
- **ZBM**: Zig cannot `zig build-exe -target loongarch64-uefi` directly (`UnsupportedCoffArchitecture`). Use **`boot/zbm/uefi/main_loongarch64.zig`** → `zbm_loongarch64.o`, then **GNU-EFI** (`make fetch-gnu-efi`) and **`objcopy --target=efi-app-loongarch64`** to produce `BOOTLOONGARCH64.EFI`. Cross GCC optional; **`zig cc`** works; **`llvm-objcopy`** or **`loongarch64-linux-gnu-objcopy`**.  
- **`make run-loongarch64`** with `LOONGARCH64_QEMU_MODE=uefi` needs **`build-esp`** and **`QEMU_EFI.fd`**.  
