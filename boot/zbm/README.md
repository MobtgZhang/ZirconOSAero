# ZirconOSAero Boot Manager (ZBM)

In-tree boot manager only — **this repository does not use GRUB** (`Makefile` enforces `BOOTLOADER=zbm`).

## Windows 7–style paths (project convention)

These names mirror the *user-visible* layout of Windows boot media; files are **ZirconOSAero’s own** formats unless stated otherwise.

| Path | Meaning |
|------|---------|
| `\Boot\BCD` | **Simplified** boot configuration store used by ZBM (`boot/zbm/common/bcd.zig`). **Not** a byte-compatible copy of Microsoft’s BCD hive. |
| `\Boot\zbm.efi` | Optional logical name in `src/config/boot.conf` (`loader_path`); firmware typically loads `\EFI\BOOT\BOOTX64.EFI` (or `BOOTAA64.EFI`, `BOOTRISCV64.EFI`, `BOOTLOONGARCH64.EFI`). |
| `\boot\kernel.elf` | Kernel image loaded by ZBM after menu selection. |

## Handoff to the kernel

ZBM builds a **Multiboot2** information block in memory (tags: mmap, cmdline, framebuffer when available, etc.). The kernel parses it via `src/boot/multiboot2_parse.zig`. The tag layout is defined by the **public Multiboot2 specification**; ZBM is the producer in this project.

## Layout in this directory

- `bios/` — MBR, VBR, Stage2 (x86 assembly; real mode + protected mode).
- `uefi/` — UEFI ZBM application (`main.zig`, LoongArch entry `main_loongarch64.zig`).
- `common/` — BCD store model, disk/GPT helpers, menu state.
- `zbm.zig` — Shared types, Multiboot2 builder, `BootContext`.

## Compliance

Clean-room implementation: **no** Windows or ReactOS source was used. Public docs (UEFI, Multiboot2, ACPI where applicable) and this project’s own data structures only.
