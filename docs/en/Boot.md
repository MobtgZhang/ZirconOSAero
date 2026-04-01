# ZirconOSAero boot flow (ZBM only)

This repository uses **only** the in-tree **ZirconOSAero Boot Manager (ZBM)**; the `Makefile` accepts `BOOTLOADER=zbm` only. The kernel consumes a **Multiboot2-style information block** produced by ZBM (or the UEFI ZBM application), as defined by the public Multiboot2 specification.

## 1. Boot path matrix

| Architecture | Primary path | Firmware chain | Notes |
|--------------|--------------|----------------|-------|
| **x86_64** | ZBM BIOS | BIOS → MBR → VBR → Stage2 → `kernel.elf` | Multiboot2 handoff from Stage2 |
| **x86_64** | ZBM UEFI | UEFI → ESP `\EFI\BOOT\BOOTX64.EFI` → `kernel.elf` | ISO: [scripts/build/mkiso-uefi-zbm.sh](../../scripts/build/mkiso-uefi-zbm.sh) |
| **aarch64** | ZBM UEFI | UEFI → ESP (e.g. `BOOTAA64.EFI`) → `kernel.elf` | Built via `zig build uefi`; run via `make run-aarch64` |
| **riscv64** | ZBM UEFI | UEFI → ESP `BOOTRISCV64.EFI` → `kernel.elf` | Zig object + GNU-EFI link: `make build-zbm-riscv64-uefi` |
| **loongarch64** | ZBM UEFI | UEFI → ESP `BOOTLOONGARCH64.EFI` → `kernel.elf` | `main_loongarch64.zig` + GNU-EFI: `make build-zbm-loongarch-uefi` |
| **loongarch64** | Dev shortcut | `qemu-system-loongarch64 -kernel` | **Development only**: no ZBM/ESP; see §8 |

**mips64el** is treated as **experimental**; prefer the four architectures above for product-style validation.

Further detail on BCD vs Windows: [boot/zbm/README.md](../../boot/zbm/README.md).

## 2. ESP layout (Windows 7–style naming, project-specific files)

Paths below are **conventions used by this project** for a Win7-like boot experience. They are **not** binary-compatible with Microsoft’s proprietary BCD store.

| Path | Role |
|------|------|
| `\Boot\BCD` | Project boot configuration data (simplified; consumed by ZBM logic in `boot/zbm/zbm.zig`) |
| `\Boot\zbm.efi` | Optional alias / secondary reference in `src/config/boot.conf` (`loader_path`) |
| `\EFI\BOOT\BOOT*.EFI` | Architecture-specific UEFI application built from `boot/zbm/uefi/` |
| `\boot\kernel.elf` | Kernel image on the ESP (or data partition, depending on image script) |

Resolution and framebuffer defaults are synchronized from root **`build.conf`** (`RESOLUTION`) via `make sync-resolution` into `src/config/*.conf`.

## 3. ZBM (ZirconOSAero Boot Manager)

### BIOS chain (x86_64)

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
    build Multiboot2 info block
    jump to kernel _start (32-bit), then long mode
```

### UEFI chain

```
UEFI firmware
  → BOOT*.EFI from boot/zbm/uefi/main.zig (and arch-specific entry where applicable)
    load kernel, show menu
    ExitBootServices
    build Multiboot2 handoff in memory
    jump to kernel entry (per-arch contract)
```

### Core library (`boot/zbm/zbm.zig`)

- Simplified **BCD** semantics (menu, timeout, entries) — **clean-room**, not Windows BCD parser compatibility
- Disk / partition detection
- Boot menu UI
- Kernel load and jump

## 4. x86_64 early start (`src/arch/x86_64/start.s`)

Entry after ZBM (Multiboot2 magic and info pointer in registers per spec).

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

**x86_64 UEFI note**: ZBM delivers a Multiboot2 information block. The kernel may still use **8259 PIC + PIT** on some paths; full ACPI/IOAPIC bring-up is incremental work (see kernel/HAL docs).

## 5. Kernel init phases (Phase 0–12)

`kernel_main` in `src/main.zig` runs phased initialization. **Documentation only** — individual phases vary in maturity; see [Roadmap.md](Roadmap.md) and README for **honest** status (not all phases are production-complete).

(Sections Phase 0–12 unchanged in intent: configuration, hardware, interrupts, VM, managers, IPC, drivers, loaders, userland, Win32, graphics, extensions, display mode — refer to [Kernel.md](Kernel.md) for detail.)

## 6. Linker scripts

| File | Arch | Load address |
|------|------|----------------|
| `link/x86_64.ld` | x86_64 | 1MB (0x100000), includes `.multiboot2`, `.uefi_vector` |
| `link/aarch64.ld` | AArch64 | 0x40080000 |
| `link/loongarch64.ld` | LoongArch64 | from `0x00200000` (QEMU virt first RAM; see §8) |
| `link/riscv64.ld` | RISC-V 64 | arch-specific |
| `link/mips64el.ld` | MIPS64 LE | experimental |
| `link/mbr.ld` | x86 | MBR at 0x7C00 |
| `link/vbr.ld` | x86 | VBR |
| `link/zbm_bios.ld` | x86 | ZBM BIOS Stage2 |

## 7. Multiboot2 handoff (ZBM → kernel)

Parsed via `src/boot/multiboot2_parse.zig` and arch `boot.zig` (e.g. x86_64). **Source**: ZBM; **format**: public Multiboot2 tag layout.

| Tag | Use |
|-----|-----|
| Memory map | Physical layout → frame allocator |
| Command line | Boot mode (cmd/powershell/desktop), theme |
| Framebuffer | Address, resolution, depth (when present) |
| Boot loader name | Identification string |

Examples: `mode=cmd`, `mode=desktop`, `desktop=aero` / `theme=aero`.

## 8. LoongArch64 boot (QEMU)

### 8.1 Development: `-kernel` (no ZBM)

- Link kernel at **`0x00200000`** per `link/loongarch64.ld` so the image fits low RAM; avoid placing the image across the low/high RAM **hole**.
- **`make run-loongarch64`** with `LOONGARCH64_QEMU_MODE=kernel` uses **`qemu-system-loongarch64 -kernel build/tmp/kernel.elf`** — **no ESP/ZBM**; serial shows `klog`.
- **Not** the product boot path; use for fast kernel iteration only.

### 8.2 Product-style: UEFI + ESP + ZBM

- Firmware discovers `\EFI\BOOT\BOOTLOONGARCH64.EFI` (ZBM).
- Build: `make build-zbm-loongarch-uefi` after `make build ARCH=loongarch64`.
- **`make run-loongarch64`** with `LOONGARCH64_QEMU_MODE=uefi` uses `build-esp` + `QEMU_EFI.fd`.

## 9. AArch64 and RISC-V64 (summary)

- **AArch64**: UEFI ZBM from `boot/zbm/uefi/main.zig`; `make run-aarch64` wires firmware + ESP.
- **RISC-V64**: `BOOTRISCV64.EFI` via `scripts/build/zbm-riscv64-efi.sh` and `make build-zbm-riscv64-uefi`.

For input/menu quirks on UEFI consoles, see the Chinese Boot doc §3 notes (menu keys) or `boot/zbm/uefi/menu_common.zig`.
