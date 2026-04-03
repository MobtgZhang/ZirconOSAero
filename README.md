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
- **User-mode system services**: Object Manager, Process Manager, I/O Manager, Security, etc.
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

状态标签：`Stub` · `Partial` · `Done` · `Verified`。API 覆盖：[docs/cn/API_COMPAT_MATRIX.md](docs/cn/API_COMPAT_MATRIX.md)。

More: `[docs/README.md](docs/README.md)` · `[docs/en/Architecture.md](docs/en/Architecture.md)` · `[docs/en/Kernel.md](docs/en/Kernel.md)` · `[docs/en/Boot.md](docs/en/Boot.md)` · `[docs/en/BuildSystem.md](docs/en/BuildSystem.md)` · `[docs/en/Roadmap.md](docs/en/Roadmap.md)`

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
│           └── wow64.zig      # WOW64 layer
├── src/desktop/           # Desktop theme Zig projects; each has resources/
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

## Phase 0–11 feature matrix（继承上游能力）


| Area                      | Status  | Notes                                                                                                                                                                                    |
| ------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ZBM boot                  | Done    | BIOS/MBR + UEFI；Windows 7 风格文本菜单                                                                                                                                                         |
| UEFI boot                 | Done    | UEFI app, Debug/Release, Phase 0–11 banner                                                                                                                                               |
| VGA                       | Done    | Text console                                                                                                                                                                             |
| Serial                    | Done    | COM1                                                                                                                                                                                     |
| Frame allocator           | Partial | 位图 + mmap 过滤；连续页伙伴见 `phys_buddy.zig`（[NT61_CONTRACT_MATRIX §0](docs/cn/NT61_CONTRACT_MATRIX.md)）                                                                                         |
| Paging                    | Partial | 四级表、恒等映射；每进程 CR3/SMEP 见契约矩阵与 `mitigations.zig`                                                                                                                                           |
| Kernel heap               | Partial | Bump 快路径 + 空闲链表 + `mm/pool` 档位；路径/IRQL 见 [docs/cn/MM_ALLOC_PATHS.md](docs/cn/MM_ALLOC_PATHS.md)；Paged 软上限与契约矩阵 §0                                                                                                                                          |
| Section objects           | Partial | 匿名节 + `ntdll` / `section.zig`；x64 `syscall` 分发 `NtCreateSection`/`NtMapViewOfSection`/`NtUnmapViewOfSection`（[MM_Section_Roadmap.md](docs/cn/MM_Section_Roadmap.md)）                     |
| IPC (LPC)                 | Partial | Queues, ports；连接/通信端口分离雏形、`section_view_handle` 占位（[Win32kArchitectureNotes.md](docs/cn/Win32kArchitectureNotes.md)）                                                                     |
| Syscall                   | Partial | `int 0x80` + `syscall`/`sysret`（`main` 链见 [SyscallABI.md](docs/cn/SyscallABI.md)）；SSDT 含 `NtCreateProcess`/`NtWaitForMultipleObjects`（专用槽 **0x57**）等；`NtQuerySystemInformation` 多类子集 + `probe`；**ssdt_stub_parity**（[ntdll_syscall_win64.zig](src/sdk/ntdll_syscall_win64.zig)） |
| IDT/ISR                   | Done    | 256 vectors                                                                                                                                                                              |
| Scheduler                 | Partial | **已实现**：每逻辑 CPU **32** 档 FIFO 分桶、`non_empty` 位图、按 **priority class** 时间片、饥饿提升、I/O boost、互斥优先级继承（多锁深度配对 `mutex_inherit_depth`）、亲和与 `home_cpu`、tick 路径 CR3 切换；**对象等待队列** + `keWait` 阻塞与 `tick` 让出（[SCHEDULER_API.md](docs/cn/SCHEDULER_API.md) 阶段 C）。**未等同 NT**：NUMA/公平份额、完整 IRQL 抢占模型、AP **INIT-SIPI** 实路径与多核 tick 仍为路线图（K2.4/K2.6）。 |
| Timer                     | Partial | **主 tick**：PIC + **PIT ~100Hz**（`ke/timer.zig`）。**单调时钟抽象**：`ke/timekeeping.zig`（调度 tick + 可选 HPET 主计数器只读）。**HPET**：MMIO 探测/频率解析见 `hal/x86_64/hpet.zig`（接 IRQ0 迁移与 LAPIC one-shot 见 [TimerPrecisionRoadmap.md](docs/cn/TimerPrecisionRoadmap.md)）。 |
| Sync                      | Done    | Event, mutex, semaphore, spinlock                                                                                                                                                        |
| Object Manager            | Partial | 类型、句柄表、命名空间子集；主机测试 [zircon_host_ob_test.zig](src/zircon_host_ob_test.zig)                                                                                                                |
| Process Manager           | Partial | 进程/线程、Process Server；隔离与 CR3 切换见契约矩阵 §0                                                                                                                                                  |
| Session Manager           | Done    | SMSS, sessions, subsystem registration                                                                                                                                                   |
| Security                  | Done    | Token, SID, access checks                                                                                                                                                                |
| I/O Manager               | Partial | 设备、驱动、`IoCompleteRequest` 与 VFS IRP 桥接；PnP/PCI 见 `acpi_pci_early.zig`                                                                                                                    |
| VFS                       | Partial | Mount points；完整 IRP/锁语义见契约矩阵                                                                                                                                                             |
| FAT32                     | Partial | `C:\` 主路径可用；与 NT 格式化工具完全互操作非目标                                                                                                                                                           |
| NTFS                      | Partial | MFT 子集与基本路径；**非**完整 NTFS（日志/压缩/稀疏/安全描述符全谱系见路线图）                                                                                                                                          |
| PE32+ loader              | Partial | Headers, imports, relocs, PEB/TEB 子集；绑定与边界情况持续对齐 SSDT                                                                                                                                    |
| PE32 loader               | Partial | 32-bit PE + WOW64；与官方 SysWOW64/SSDT 不对齐                                                                                                                                                  |
| ELF loader                | Partial | ELF64 头与加载子集；与 glibc 动态链接全兼容非目标                                                                                                                                                          |
| ntdll                     | Partial | Native API 子集；`RtlVerifyVersionInfo`（`os_version`）；服务号见 SSDT 路线图                                                                                                                        |
| kernel32                  | Partial | Win32 base API 子集                                                                                                                                                                        |
| user32                    | Partial | 窗口/消息/类；NC HitTest、DWM 广播子集；完整 NC 序列见契约矩阵                                                                                                                                                |
| gdi32                     | Partial | DC/原语/字体/位图子集；分阶段见 `gdi32.zig` 头注释与契约矩阵                                                                                                                                                  |
| Console                   | Done    | Console runtime                                                                                                                                                                          |
| CMD                       | Done    | dir, cd, set, ver, systeminfo, tasklist, …                                                                                                                                               |
| .NET Shell（用户态，预留）        | Planned | 内核内 ZirconShell 已移除；由未来 .NET 用户态宿主提供                                                                                                                                                     |
| csrss                     | Partial | Win32 server, stations, desktops, GUI dispatch                                                                                                                                           |
| Exec engine               | Partial | PE load, DLL bind, lifecycle                                                                                                                                                             |
| WOW64                     | Partial | PE32, thunk；32→64 服务号须对齐 `ssdt_nt61.zig`（与旧 `SYS_`* 已分离）— 见 `wow64.zig`                                                                                                                  |
| Registry runtime          | Partial | 内存树 + `Mouse`/`Desktop`/`HKLM\...\Windows\DWM`/`Memory Management` 等键；RegF/hive 持久化 Planned                                                                                              |
| Aero / DWM (kernel shell) | Partial | 脏区/Present 契约、`thumb_refresh` 节流、任务栏缩略 `enqueueIconicThumbnailRequest` 与 Flip3D 表面枚举；**Aero 模糊/合成仍以 CPU 为主**（`blur_budget`）。**VirtIO-GPU**：`SET_SCANOUT` + 屏前 RAM `RESOURCE_FLUSH`（`isScanoutActive`）；≤32×32 scratch `TRANSFER` PoC 仍保留。**NVIDIA**：PCI/BAR0 + 可选 4MiB 可预取 BAR 诊断映射、`IOCTL_NVIDIA_BAR0_FIRST_U32`（非 WDDM）。见 [AeroDesktopRuntime.md](docs/cn/AeroDesktopRuntime.md)、契约矩阵 §4.1、[SOFTWARE_COMPOSITOR_WDDM.md](docs/cn/SOFTWARE_COMPOSITOR_WDDM.md) |
| 多架构 Win32 栈               | Partial | **x86_64** 为主验证路径；riscv64/LoongArch/MIPS 引导与桌面见各 `arch` 文档与 CI 说明                                                                                                                        |


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

