# ZirconOSAero（NT 6.1 目标）

**ZirconOSAero** 是以 **NT 6.1（Windows 7）** ABI/体验为目标的独立 clean-room 内核与用户态栈；Aero 桌面、**仅 ZBM 引导**（BIOS/MBR 与 UEFI）。**本仓库实现与文档均为独立演进，不复制 Windows/ReactOS 源码**。

**独立项目声明**：非 Microsoft 产品；「Windows」「Windows 7」等为商标说明，仅用于兼容目标描述。第三方与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。



## Screenshots


|                                 |                                 |           |
| ------------------------------- | ------------------------------- | --------- |
| ZBM — Windows 7–style text menu | Shell — Windows 7 Aero (NT 6.1) | CMD shell |


**中文说明**：[README_cn.md](README_cn.md)

[CI](https://github.com/MobtgZhang/ZirconOSAero/actions/workflows/ci.yml)

**CI / 本地**：`zig build test`；`bash scripts/ci-qemu-smoke.sh`；Zig **0.15.2**（见 [docs/REPRODUCE_BUILD.md](docs/REPRODUCE_BUILD.md)、[.github/workflows/ci.yml](.github/workflows/ci.yml)）。测试索引：[docs/cn/MVT_NT61.md](docs/cn/MVT_NT61.md)。

## Design

- **NT-style hybrid microkernel**: scheduling, virtual memory, IPC, interrupts, and syscalls in the kernel
- **Hybrid executive (as-built)**: Object Manager, Memory Manager, process/thread core, I/O Manager, Security, and loaders live **in kernel** today (`src/ob/`, `src/mm/`, `src/ps/`, `src/io/`, `src/se/`, `src/loader/`). **User-mode** bring-up today is mainly **Process Server** (PID 1, `server.zig`) and **SMSS** (PID 2, `smss.zig`). Splitting Ob/IO/Security into standalone user processes is **planned**, not done — [docs/en/Servers.md](docs/en/Servers.md), [docs/cn/LPC_USER_SERVERS_CONTRACT.md](docs/cn/LPC_USER_SERVERS_CONTRACT.md).
- **Win32 compatibility layer** (**subset**, milestone-driven; not binary-compatible with Microsoft DLLs): in-repo ntdll/kernel32/kernelbase-style APIs and the console — see [NT61_CONTRACT_MATRIX.md](docs/cn/NT61_CONTRACT_MATRIX.md), [API_COMPAT_MATRIX.md](docs/cn/API_COMPAT_MATRIX.md)
- **Win32 subsystem server** (**partial**): csrss-style process registration and messaging hooks; full window-station/desktop lifecycle is phased — [LPC_NT61_HANDSHAKE.md](docs/cn/LPC_NT61_HANDSHAKE.md)
- **Win32 execution engine** (**subset**): PE loading, DLL binding, process creation, API dispatch for supported paths only
- **Graphics subsystem** (**partial**): user32 (windows/messages) and gdi32 (drawing/fonts/bitmaps) for Aero/shell scenarios — not full GDI (ROP, full font rasterization, full DC model)
- **WOW64** (**partial**): PE32 loading, 32→64 syscall thunking, 32-bit PEB/TEB where implemented — full SysWOW64 is [deferred](docs/cn/NT61_DEFERRED_SURFACES.md)
- **Text shell**: **CMD** in-kernel；高级脚本宿主计划为 **用户态 .NET**（非本仓库内核实现）
- **Dual filesystem**: FAT32 (system volume) and NTFS (data volume)
- **Multi-architecture**: x86_64 (primary), aarch64, loongarch64, riscv64, mips64el

**流程与契约（必读）**：[docs/cn/PROCESS_NT61.md](docs/cn/PROCESS_NT61.md) · [docs/cn/NT61_CONTRACT_MATRIX.md](docs/cn/NT61_CONTRACT_MATRIX.md)（与下方矩阵 **Status** 列同源；**Partial / Stub** 即非 Done）· [docs/cn/NT61_DEFERRED_SURFACES.md](docs/cn/NT61_DEFERRED_SURFACES.md) · [docs/cn/DWM_NOTIFY_MODEL_NT61.md](docs/cn/DWM_NOTIFY_MODEL_NT61.md) · [docs/cn/MVT_NT61.md](docs/cn/MVT_NT61.md) · [docs/en/COPYRIGHT_AND_SOURCES.md](docs/en/COPYRIGHT_AND_SOURCES.md) / [docs/cn/COPYRIGHT_AND_SOURCES.md](docs/cn/COPYRIGHT_AND_SOURCES.md)

**调度与定时（行为细节）**：[docs/cn/SCHEDULER_API.md](docs/cn/SCHEDULER_API.md)（就绪队列、时间片、饥饿与 I/O boost）· [docs/cn/TimerPrecisionRoadmap.md](docs/cn/TimerPrecisionRoadmap.md)（PIT 以外的高分辨率路径）

状态标签：`Stub` · `Partial` · `Done` · `Verified`。**工程三态（可读性）**：`Verified` = CI/`zig build test` 或 QEMU 冒烟可重复；`InProgress` = 接口已建、语义仍在对齐；`Planned` = 仅文档/桩。API 覆盖：[docs/cn/API_COMPAT_MATRIX.md](docs/cn/API_COMPAT_MATRIX.md)。

More docs: see [`docs/README.md`](docs/README.md). Contract matrix: [`docs/cn/NT61_CONTRACT_MATRIX.md`](docs/cn/NT61_CONTRACT_MATRIX.md); process spec: [`docs/cn/PROCESS_NT61.md`](docs/cn/PROCESS_NT61.md); test index: [`docs/cn/MVT_NT61.md`](docs/cn/MVT_NT61.md).

## Repository layout

```
ZirconOSAero/
├── build.zig              # Zig build
├── build.zig.zon          # Zig dependencies
├── run.sh                 # Build and run helper
├── Makefile               # Convenience targets (optional); primary entry is `zig build` (see docs/en/BuildSystem.md)
├── assets/                # Logo and screenshots
├── scripts/               # Build helpers (see scripts/README.md)
├── gnu-efi/               # LoongArch GNU-EFI output (gitignored; make fetch-gnu-efi)
├── boot/
│   └── zbm/               # ZBM：BIOS/MBR、BCD、菜单；UEFI 源在 zbm/uefi/（main.zig / main_riscv64.zig / main_loongarch64.zig）
├── link/                  # Per-architecture linker scripts
│   └── x86_64.ld / aarch64.ld / loongarch64.ld / riscv64.ld / mips64el.ld
├── src/                   # Kernel sources
│   ├── main.zig           # Kernel entry (Phase 0–12 init; roadmap milestones remain 0–11 — docs/en/Boot.md)
│   ├── config/            # Config parser + embedded defaults (*.conf, defaults.zig)
│   ├── arch/              # Architecture code
│   │   ├── x86_64/        #   Multiboot2, paging, IDT, ISR, syscall
│   │   ├── aarch64/       #   AArch64 boot and paging
│   │   └── (loongarch64, riscv64, mips64el)
│   ├── hal/               # Hardware abstraction
│   │   ├── x86_64/        #   VGA, PIC, PIT, port I/O, serial, GDT, framebuffer
│   │   ├── aarch64/       #   GIC, timer, PL011 UART
│   │   └── loongarch64/   #   ramfb, TLB flush, SMP IPI, CPU topology
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
│           └── wow64.zig      # WOW64 layer
├── src/desktop/           # Desktop resources (shipped theme: aero/ only; see desktop.conf)
├── src/fonts/             # Shared open fonts (make fonts / scripts/fonts/fetch-fonts.sh)
└── docs/                  # Design docs (en/ and cn/)
```

## Desktop（Aero）

本仓库仅内置 **Windows 7 Aero** 壳：Zig 与静态资源在 `src/desktop/aero/`（含 `resources/`）。

字体：`make fonts` 或 `scripts/fonts/fetch-fonts.sh` 填充 `src/fonts/`。

LoongArch UEFI 链接 GNU-EFI：`make fetch-gnu-efi`（输出在 `gnu-efi/`；见 `scripts/README.md`）。

`src/config/desktop.conf`（编译期嵌入）中 `[desktop] theme` 仅 `**aero`** 或 `**none**`（无图形壳）。

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

Install Zig from [ziglang.org](https://ziglang.org/download/) and add it to `PATH`. **要求**：`build.zig.zon` 中 `minimum_zig_version`（当前 **0.15.0+**）；CI 锁定 **0.15.2**。首次构建若缺壁纸 PNG：先执行 `bash scripts/fetch-assets.sh` 或 `make fetch-assets`（生成占位图，可日后替换）。

## Build and run

```bash
# run.sh (recommended)
./run.sh build              # Kernel (Debug)
./run.sh build-release      # Kernel (Release)
./run.sh iso                # UEFI ISO（ZBM；x86_64）
./run.sh run                # 按 build.conf 运行 QEMU（默认 UEFI+ZBM）
./run.sh run-debug          # ZBM MBR 磁盘 + GDB
./run.sh run-release        # Release 内核运行
./run.sh run-uefi           # 显式 UEFI+ZBM（x86_64）
./run.sh run-uefi-aarch64   # UEFI (aarch64)
./run.sh run-aarch64        # AArch64 bare metal
./run.sh run-loongarch64    # LoongArch64 QEMU（-kernel + ramfb）
./run.sh run-loongarch64-uefi # LoongArch64 UEFI+ZBM
./run.sh run-riscv64        # RISC-V64 UEFI
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

## Completion disclaimer（完成度说明）

Clean-room，行为以 [Microsoft Learn](https://learn.microsoft.com/)、WDK 与硬件规范为准；**不**复制 Windows/ReactOS/Wine 源码。矩阵中 **Done** = QEMU/CI 主路径可演示且与 [契约矩阵](docs/cn/NT61_CONTRACT_MATRIX.md) 一致，**不等于**与商业 Windows 7 等价；以矩阵 + `zig build test` + 源码为准。多架构 CI 与引导见 [docs/en/Boot.md](docs/en/Boot.md)。

## Phase 0–11 feature matrix

Status from code and contract; **Partial / Stub** = not all done. Detailed notes and inline links: [`docs/cn/NT61_CONTRACT_MATRIX.md`](docs/cn/NT61_CONTRACT_MATRIX.md).

| Area | Status | Notes |
|------|--------|-------|
| ZBM boot | Done | BIOS/MBR + UEFI; Windows 7-style text menu |
| UEFI boot | Done | UEFI app, Debug/Release |
| VGA | Done | Text console |
| Serial | Done | COM1 |
| Frame allocator | Partial | Bitmap + mmap; buddy see `phys_buddy.zig` |
| Paging | Partial | 4-level tables, identity mapping; per-process CR3 + SMEP |
| Kernel heap | Partial | Bump fast path + free list + `mm/pool` sizes |
| Section objects | Partial | Anonymous sections + `ntdll`/`section.zig` |
| IPC (LPC) | Partial | Queues, ports; connection/communication port separation |
| Syscall | Partial | **`syscall`/`sysret` only**; SSDT subset (incl. `NtCreateUserProcess` 0xAA, `NtDeviceIoControlFile` 0x52, etc.) |
| IDT/ISR | Done | 256 vectors |
| Scheduler | Partial | Per-CPU 32-slot FIFO buckets, priority class timeslices, starvation boost, I/O boost, mutex priority inheritance |
| Timer | Partial | PIC + PIT ~100Hz; HPET high-precision on roadmap |
| Sync | Partial | Event/Mutex/Semaphore/SpinLock; partial ntdll handle paths |
| Object Manager | Partial | Types, handle table, namespace subset |
| Process Manager | Partial | Processes/threads, Process Server; CR3/isolation |
| Session Manager | Done | SMSS, sessions, subsystem registration |
| Security | Partial | Tokens, SIDs, `checkAccess`-style checks; DACL/AuthZ on roadmap |
| I/O Manager | Partial | Devices, drivers, `IoCompleteRequest` with VFS IRP |
| VFS | Partial | Mount points; full semantics in contract matrix |
| FAT32 | Partial | `C:\` main path |
| NTFS | Partial | MFT subset and basic paths; journal/compress on roadmap |
| PE32+ loader | Partial | Headers, imports, relocs, PEB/TEB subset |
| PE32 loader | Partial | 32-bit PE + WOW64 |
| ELF loader | Partial | ELF64 header and load subset |
| ntdll | Partial | Native API subset (incl. `RtlVerifyVersionInfo`) |
| kernel32 | Partial | Win32 base API subset |
| user32 | Partial | Windows/messages/classes; NC HitTest, DWM broadcast subset |
| gdi32 | Partial | DC/primitives/fonts/bitmaps subset |
| Console | Done | Console runtime |
| CMD | Done | dir, cd, set, ver, systeminfo, tasklist, … |
| .NET Shell (user-mode, planned) | Planned | In-kernel ZirconShell removed |
| csrss | Partial | Win32 server, stations, desktops, GUI dispatch |
| Exec engine | Partial | PE load, DLL bind, lifecycle |
| WOW64 | Partial | PE32, thunk; see `subsystems/win32/wow64/` submodule |
| Registry runtime | Partial | In-memory tree + keys; RegF/hive persistence on roadmap |
| Aero / DWM (kernel shell) | Partial | Dirty/Present contract, Aero blur (CPU synthesis); VirtIO-GPU <=32x32 PoC; NVIDIA PCI/BAR0 diagnostic mapping |
| Multi-arch Win32 stack | Partial | **x86_64** primary; LoongArch64 UEFI/ZBM + ramfb desktop works; AArch64/RISC-V64 boot scaffold; MIPS64el empty |

## Milestones

- **Phase 0** — Toolchain and QEMU debugging  
- **Phase 1** — Boot and early kernel (GDT/Multiboot2/frame/heap)  
- **Phase 2** — Traps, timer, scheduler  
- **Phase 3** — VM and user mode  
- **Phase 4** — Objects, handles, process core  
- **Phase 5** — IPC and system services (SMSS/LPC)  
- **Phase 6** — I/O, filesystems (FAT32/NTFS), drivers  
- **Phase 7** — Loaders (PE32/PE32+/ELF, DLLs, imports, relocs)  
- **Phase 8** — Native userland (ntdll/kernel32, CMD)  
- **Phase 9** — Win32 subsystem (csrss, exec engine, PE/DLL)  
- **Phase 10** — Graphics (user32, gdi32, message queue, GUI dispatch)  
- **Phase 11** — WOW64 (PE32, thunking, 32-bit PEB/TEB)

