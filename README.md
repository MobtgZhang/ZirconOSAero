# ZirconOSAero（NT 6.1 目标）

**ZirconOSAero** 基于 [ZirconOS](https://github.com/MobtgZhang/ZirconOS) 路线，以 **NT 6.1（Windows 7）** 体验为默认目标：Aero 桌面、**仅 ZBM 引导**（BIOS/MBR 与 UEFI），**不包含 GRUB**。

<p align="center">
  <img src="assets/ZirconOS_logo.svg" alt="ZirconOS logo" width="480" />
</p>

## Screenshots

<p align="center">
  <img src="assets/screenshot-zbm.png" alt="ZBM boot manager (Windows 7 style)" width="70%" />
</p>
<p align="center"><em>ZirconOS Boot Manager (ZBM) — Windows 7–style text menu</em></p>

<p align="center">
  <img src="assets/screenshot-aero.png" alt="Windows 7 Aero desktop" width="70%" />
</p>
<p align="center"><em>Shell — Windows 7 Aero（NT 6.1）唯一内置桌面</em></p>

<p align="center">
  <img src="assets/screenshot-cmd.png" alt="CMD shell" width="70%" />
</p>
<p align="center"><em>CMD shell</em></p>

**中文说明**：[README_cn.md](README_cn.md)

## Design

- **NT-style hybrid microkernel**: scheduling, virtual memory, IPC, interrupts, and syscalls in the kernel
- **User-mode system services**: Object Manager, Process Manager, I/O Manager, Security, etc.
- **Win32 compatibility layer**: ntdll, kernel32, kernelbase, and the console subsystem
- **Win32 subsystem server**: csrss-style management, window stations, and desktops
- **Win32 execution engine**: PE loading, DLL binding, process creation, API dispatch
- **Graphics subsystem**: user32 (windows/messages) and gdi32 (drawing/fonts/bitmaps)
- **WOW64**: PE32 loading, 32→64 syscall thunking, 32-bit PEB/TEB
- **Dual shell**: CMD and PowerShell-style shells
- **Dual filesystem**: FAT32 (system volume) and NTFS (data volume)
- **Multi-architecture**: x86_64 (primary), aarch64, loongarch64, riscv64, mips64el

**开发流程（必读）**：[docs/cn/PROCESS_NT61.md](docs/cn/PROCESS_NT61.md)

Documentation: [`docs/README.md`](docs/README.md) · [`docs/en/Architecture.md`](docs/en/Architecture.md) · [`docs/en/Kernel.md`](docs/en/Kernel.md) · [`docs/en/Boot.md`](docs/en/Boot.md) · [`docs/en/Servers.md`](docs/en/Servers.md) · [`docs/en/Subsystems.md`](docs/en/Subsystems.md) · [`docs/en/BuildSystem.md`](docs/en/BuildSystem.md) · [`docs/en/Roadmap.md`](docs/en/Roadmap.md)

## Repository layout

```
ZirconOSAero/
├── build.zig              # Zig build
├── build.zig.zon          # Zig dependencies
├── run.sh                 # Build and run helper
├── Makefile               # Make entry point
├── assets/                # Logo and screenshots
├── scripts/               # Build helpers (see scripts/README.md)
├── gnu-efi/               # LoongArch GNU-EFI output (gitignored; make fetch-gnu-efi)
├── boot/
│   ├── uefi/main.zig      # UEFI ZBM (x86_64 / aarch64; LoongArch 见 main_loongarch64.zig)
│   └── zbm/               # ZBM：BIOS/MBR、BCD、菜单（Windows 7 风格）
├── link/                  # Per-architecture linker scripts
│   └── x86_64.ld / aarch64.ld / loongarch64.ld / riscv64.ld / mips64el.ld
├── src/                   # Kernel sources
│   ├── main.zig           # Kernel entry (Phase 0–11 boot path)
│   ├── config/            # Config parser + embedded defaults (*.conf, defaults.zig)
│   ├── arch/              # Architecture code
│   │   ├── x86_64/        #   Multiboot2, paging, IDT, ISR, syscall
│   │   ├── aarch64/       #   AArch64 boot and paging
│   │   └── (loongarch64, riscv64, mips64el)
│   ├── hal/               # Hardware abstraction
│   │   ├── x86_64/        #   VGA, PIC, PIT, port I/O, serial, GDT, framebuffer
│   │   └── aarch64/       #   GIC, timer, PL011 UART
│   ├── drivers/           # Device drivers
│   │   └── video/         #   VGA, HDMI, framebuffer, display manager
│   ├── ke/                # Kernel Executive — scheduling, timer, interrupts, sync
│   ├── mm/                # Memory manager — physical frames, VM, heap
│   ├── ob/                # Object Manager — objects, handle table, namespace
│   ├── ps/                # Process subsystem — processes and threads
│   ├── se/                # Security — token, SID, access checks
│   ├── io/                # I/O Manager — devices, drivers, IRPs
│   ├── lpc/               # LPC — IPC ports and messages
│   ├── rtl/               # Runtime — kernel logging
│   ├── fs/                # File systems — VFS, FAT32, NTFS
│   ├── loader/            # Loader — PE32/PE32+/ELF
│   ├── libs/              # User-mode API libraries
│   │   ├── ntdll.zig      #   Native API (Nt*/Rtl*/Dbg*)
│   │   └── kernel32.zig   #   Win32 base API
│   ├── servers/           # System services
│   │   ├── server.zig     #   Process Server (PID 1)
│   │   └── smss.zig       #   Session Manager (SMSS)
│   └── subsystems/        # Subsystems
│       └── win32/         #   Win32 subsystem
│           ├── subsystem.zig  # csrss server
│           ├── exec.zig       # Win32 execution engine
│           ├── user32.zig     # Windowing API
│           ├── gdi32.zig      # GDI API
│           ├── console.zig    # Console runtime
│           ├── cmd.zig        # CMD
│           ├── powershell.zig # PowerShell-style shell
│           └── wow64.zig      # WOW64 layer
├── src/desktop/           # Desktop theme Zig projects; each has resources/
├── src/fonts/             # Shared open fonts (make fonts / scripts/fonts/fetch-fonts.sh)
└── docs/                  # Design docs (en/ and cn/)
```

## Desktop（Aero）

本仓库仅内置 **Windows 7 Aero** 壳：Zig 与静态资源在 `src/desktop/aero/`（含 `resources/`）。

字体：`make fonts` 或 `scripts/fonts/fetch-fonts.sh` 填充 `src/fonts/`。

LoongArch UEFI 链接 GNU-EFI：`make fetch-gnu-efi`（输出在 `gnu-efi/`；见 `scripts/README.md`）。

`src/config/desktop.conf`（编译期嵌入）中 `[desktop] theme` 仅 **`aero`** 或 **`none`**（无图形壳）。

```ini
[desktop]
theme = aero
color_scheme = zircon_blue
```

## Dependencies

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y xorriso dosfstools mtools \
    qemu-system-x86 qemu-system-arm ovmf
```

Install Zig from [ziglang.org](https://ziglang.org/download/) and add it to `PATH`.

## Build and run

```bash
# run.sh (recommended)
./run.sh build              # Kernel (Debug)
./run.sh build-release      # Kernel (Release)
./run.sh iso                # UEFI ISO（ZBM，无 GRUB；x86_64）
./run.sh run                # 按 build.conf 运行 QEMU（默认 UEFI+ZBM）
./run.sh run-debug          # ZBM MBR 磁盘 + GDB
./run.sh run-release        # Release 内核运行
./run.sh run-uefi           # 显式 UEFI+ZBM（x86_64）
./run.sh run-uefi-aarch64   # UEFI (aarch64)
./run.sh run-aarch64        # AArch64 bare metal
./run.sh clean              # Clean
./run.sh help               # Help

# Make shortcuts
make run
make run-debug
make clean
make help

# Zig directly
zig build -Darch=x86_64 -Ddebug=true -Denable_idt=true
```

## Phase 0–11 feature matrix（继承上游能力）

| Area | Status | Notes |
|------|--------|--------|
| ZBM boot | Done | BIOS/MBR + UEFI；Windows 7 风格文本菜单 |
| UEFI boot | Done | UEFI app, Debug/Release, Phase 0–11 banner |
| VGA | Done | Text console |
| Serial | Done | COM1 |
| Frame allocator | Done | Bitmap allocator |
| Paging | Done | Four-level tables, identity map |
| Kernel heap | Done | Bump allocator |
| IPC (LPC) | Done | Queues, send/receive, ports |
| Syscall | Done | int 0x80 dispatch |
| IDT/ISR | Done | 256 vectors |
| Scheduler | Done | Round-robin |
| Timer | Done | PIC + PIT ~100Hz |
| Sync | Done | Event, mutex, semaphore, spinlock |
| Object Manager | Done | Types, handle table, namespace, waitable |
| Process Manager | Done | Processes/threads, Process Server |
| Session Manager | Done | SMSS, sessions, subsystem registration |
| Security | Done | Token, SID, access checks |
| I/O Manager | Done | Devices, drivers, IRP dispatch |
| VFS | Done | Mount points |
| FAT32 | Done | Files/dirs on `C:\` |
| NTFS | Done | MFT, files/dirs on `D:\` |
| PE32+ loader | Done | Headers, DLLs, imports, relocs, PEB/TEB |
| PE32 loader | Done | 32-bit PE, WOW64 |
| ELF loader | Done | ELF64 headers, segments, shared objects |
| ntdll | Done | Native API surface |
| kernel32 | Done | Win32 base API |
| user32 | Done | Windows, messages, classes, UI primitives, input |
| gdi32 | Done | DC, primitives, fonts, bitmaps, BitBlt |
| Console | Done | Console runtime |
| CMD | Done | dir, cd, set, ver, systeminfo, tasklist, … |
| PowerShell | Done | cmdlet-style commands |
| csrss | Done | Win32 server, stations, desktops, GUI dispatch |
| Exec engine | Done | PE load, DLL bind, lifecycle |
| WOW64 | Done | PE32, syscall thunking, 32-bit PEB/TEB |

## Milestones

- **Phase 0** — Toolchain and QEMU debugging  
- **Phase 1** — Boot and early kernel (GDT/Multiboot2/frame/heap)  
- **Phase 2** — Traps, timer, scheduler  
- **Phase 3** — VM and user mode  
- **Phase 4** — Objects, handles, process core  
- **Phase 5** — IPC and system services (SMSS/LPC)  
- **Phase 6** — I/O, filesystems (FAT32/NTFS), drivers  
- **Phase 7** — Loaders (PE32/PE32+/ELF, DLLs, imports, relocs)  
- **Phase 8** — Native userland (ntdll/kernel32, CMD, PowerShell)  
- **Phase 9** — Win32 subsystem (csrss, exec engine, PE/DLL)  
- **Phase 10** — Graphics (user32, gdi32, message queue, GUI dispatch)  
- **Phase 11** — WOW64 (PE32, thunking, 32-bit PEB/TEB)  
