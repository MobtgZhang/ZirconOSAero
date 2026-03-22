# ZirconOS build system

## 1. Toolchain

| Tool | Role |
|------|------|
| Zig | Compiler and build system (no libc for kernel) |
| Make | Convenience entry; reads `build.conf` and runs `zig build` |
| GRUB | Build bootable ISOs |
| QEMU | Virtual machine |
| xorriso / mtools | ISO creation |

## 2. `build.conf`

Persistent build configuration.

| Key | Values | Default | Notes |
|-----|--------|---------|-------|
| `ARCH` | x86_64, aarch64, loongarch64, riscv64, mips64el | x86_64 | Target CPU |
| `BOOT_METHOD` | mbr, uefi | uefi | Firmware style |
| `BOOTLOADER` | zbm | zbm | Bootloader (ZBM only in this tree) |
| `DESKTOP` | aero, none | aero | Desktop shell (Aero only) |
| `OPTIMIZE` | Debug, ReleaseSafe, ReleaseFast, ReleaseSmall | Debug | Optimization |
| `RESOLUTION` | WxHxdepth | 1024x768x32 | Display |
| `QEMU_MEM` | size | 512M | QEMU RAM (x86, etc.) |
| `QEMU_MEM_LOONGARCH64` | size | 1536M | `make run-loongarch64`; `qemu-system-loongarch64 -M virt` needs **> 1G** |
| `LOONGARCH64_FIRMWARE_DIR` | path | `~/Firmware/LoongArchVirtMachine` | `QEMU_EFI.fd` / `QEMU_VARS.fd`; falls back to `firmware/` EDK2 nightly names |
| `LOONGARCH64_BOOT_EFI` | file | (auto) | If `BOOTLOONGARCH64.EFI` exists, it is copied to ESP `\EFI\BOOT\`; else chain-load from Shell |
| `ENABLE_IDT` | true, false | true | Enable IDT |
| `DEBUG_LOG` | true, false | true | Debug logging |
| `GRUB_MENU` | all, minimal | minimal | GRUB menu layout |

### Overrides

Environment variables and make args override `build.conf`:

```bash
make DESKTOP=aero BOOT_METHOD=uefi BOOTLOADER=zbm
```

### Interactive config

```bash
python3 scripts/configure.py
```

## 3. Build pipeline

```
run.sh / make
    │
    ├─ read build.conf
    │
    ├─ scripts/gen_grub_cfg.py (GRUB config)
    │
    └─ zig build -Darch=... -Ddebug=... -Denable_idt=...
        │
        ├─ kernel → build/tmp/kernel.elf
        ├─ UEFI app → zirconos.efi (if UEFI)
        ├─ ZBM → MBR/VBR/Stage2 (if ZBM)
        └─ ISO → build/release/zirconos-1.0.0-{arch}.iso
```

## 4. `run.sh` (recommended)

### Build

```bash
./run.sh build              # Debug kernel
./run.sh build-release      # Release kernel
./run.sh iso                # ISO image
./run.sh clean              # Clean outputs
./run.sh help               # Help
```

### Run

```bash
./run.sh run                # BIOS
./run.sh run-debug          # BIOS + GDB server
./run.sh run-release        # BIOS Release
./run.sh run-uefi           # UEFI x86_64
./run.sh run-uefi-aarch64   # UEFI AArch64
./run.sh run-aarch64        # AArch64 bare metal
```

## 5. Make

```bash
make run
make run-debug
make clean
make help

make run BOOTLOADER=zbm BOOT_METHOD=mbr
make run DESKTOP=aero ARCH=x86_64
```

## 6. Direct Zig

```bash
zig build -Darch=x86_64 -Ddebug=true -Denable_idt=true
```

## 7. Outputs

| Artifact | Path | Notes |
|----------|------|-------|
| Kernel ELF | `build/tmp/kernel.elf` | Multiboot2 kernel |
| UEFI app | `zirconos.efi` | UEFI loader |
| ZBM MBR | `build/tmp/mbr.bin` | |
| ZBM VBR | `build/tmp/vbr.bin` | |
| ZBM Stage2 | `build/tmp/stage2.bin` | |
| ISO | `build/release/zirconos-1.0.0-{arch}.iso` | |

## 8. System configuration files

Defaults live under `src/config/` and are embedded at compile time with `@embedFile`:

| File | Role |
|------|------|
| `src/config/system.conf` | Hostname, memory, scheduler, display, filesystems |
| `src/config/boot.conf` | Timeouts, Multiboot args, UEFI/ZBM options |
| `src/config/desktop.conf` | Theme, DWM, taskbar, fonts |
| `src/config/defaults.zig` | Embeds the `.conf` files |

`src/config/config.zig` parses and exposes them at runtime.

## 9. Dependencies

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y grub-pc-bin grub-common xorriso mtools \
    qemu-system-x86 qemu-system-arm ovmf
```

### Zig

Download from [ziglang.org](https://ziglang.org/download/) and add to `PATH`.

## 10. Desktop themes and fonts

Theme sources and `resources/` live under `src/desktop/aero/`.

Download fonts into `src/fonts/`:

```bash
make fonts
# or: ./scripts/fonts/fetch-fonts.sh
```

## 11. Tests

```bash
python3 tests/run_all.py

python3 tests/test_build_config.py
python3 tests/test_boot_combinations.py
```

## 12. Debugging

### GDB

```bash
./run.sh run-debug
# another terminal
gdb build/tmp/kernel.elf
(gdb) target remote :1234
(gdb) break kernel_main
(gdb) continue
```

### Serial log

With `DEBUG_LOG=true`, the kernel logs on COM1; QEMU typically forwards serial to the terminal.
