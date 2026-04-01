# ZirconOSAero（NT 6.1 目标）

**ZirconOSAero** 以 **NT 6.1（Windows 7）** ABI/体验为目标，独立 clean-room 实现；Aero 桌面、**仅 ZBM 引导**（BIOS/MBR 与 UEFI），**不包含 GRUB**。**不复制 Windows/ReactOS 源码**。

**独立项目声明**：本仓库并非 Microsoft 或 Windows 的产品，未获其赞助或背书。「Windows」「Windows 7」等商标归 Microsoft Corporation 及其关联公司所有，本文档中的表述仅用于描述外观兼容或技术类比。实现为原创或与开源许可明确的第三方组件（见 [THIRD_PARTY.md](THIRD_PARTY.md)）。

<p align="center">
  <img src="assets/ZirconOS_logo.svg" alt="ZirconOSAero" width="480" />
</p>

## 截图

<p align="center">
  <img src="assets/screenshot-zbm.png" alt="ZBM 引导管理器" width="70%" />
</p>
<p align="center"><em>ZirconOSAero Boot Manager (ZBM) — Windows 7 风格文本菜单</em></p>

<p align="center">
  <img src="assets/screenshot-aero.png" alt="ZirconOSAero Aero 桌面" width="70%" />
</p>
<p align="center"><em>Shell — Windows 7 Aero（NT 6.1）唯一内置桌面</em></p>

<p align="center">
  <img src="assets/screenshot-cmd.png" alt="CMD 命令提示符" width="70%" />
</p>
<p align="center"><em>CMD shell</em></p>

**English**: [README.md](README.md)

[![CI](https://github.com/MobtgZhang/ZirconOSAero/actions/workflows/ci.yml/badge.svg)](https://github.com/MobtgZhang/ZirconOSAero/actions/workflows/ci.yml)

**CI 与本地复现**：`zig build test`（堆、SSDT、安全 DAC 主机测试）；`zig build install -Doptimize=ReleaseSafe -Darch=x86_64`；无头烟测 `bash scripts/ci-qemu-smoke.sh`（构建 ZBM MBR 盘、校验内核 ELF 内嵌横幅，并可选串口增强断言）。详见 [.github/workflows/ci.yml](.github/workflows/ci.yml)。

**推荐编译器版本**：与 CI 一致，当前为 **Zig 0.15.2**（见 `zig version` 与 workflow）。

## 设计理念

- **NT 风格混合微内核**：调度、虚拟内存、IPC、中断与系统调用在内核中实现
- **用户态系统服务**：Object Manager、Process Manager、I/O Manager、Security 等
- **Win32 兼容层**：ntdll、kernel32、kernelbase 与控制台子系统
- **Win32 子系统服务器**：csrss 风格管理、窗口站与桌面
- **Win32 执行引擎**：PE 加载、DLL 绑定、进程创建、API 分发
- **图形子系统**：user32（窗口/消息）与 gdi32（绘图/字体/位图）
- **WOW64**：PE32 加载、32→64 系统调用 thunk、32 位 PEB/TEB
- **双 Shell**：CMD 与 **ZirconShell**（PowerShell 风格 cmdlet 子集，与 Microsoft PowerShell 不兼容）
- **双文件系统**：FAT32（系统卷）与 NTFS（数据卷）
- **多架构**：x86_64（主路径）、aarch64、loongarch64、riscv64、mips64el

**开发流程（必读）**：[docs/cn/PROCESS_NT61.md](docs/cn/PROCESS_NT61.md)

**契约与完成度（必读）**：[docs/cn/NT61_CONTRACT_MATRIX.md](docs/cn/NT61_CONTRACT_MATRIX.md)（与下方矩阵 **Status** 列交叉引用；**Partial / Stub** 表示非 Done）。

**实现状态标签**：`Stub`（骨架）· `Partial`（部分语义）· `Done`（与公开文档一致）· `Verified`（含自动化回归）。API 覆盖见 [docs/cn/API_COMPAT_MATRIX.md](docs/cn/API_COMPAT_MATRIX.md)。

设计文档：[`docs/README.md`](docs/README.md) · [`docs/cn/README.md`](docs/cn/README.md) · [`docs/cn/Architecture.md`](docs/cn/Architecture.md) · [`docs/cn/Kernel.md`](docs/cn/Kernel.md) · [`docs/cn/Boot.md`](docs/cn/Boot.md) · [`docs/cn/Servers.md`](docs/cn/Servers.md) · [`docs/cn/Subsystems.md`](docs/cn/Subsystems.md) · [`docs/cn/BuildSystem.md`](docs/cn/BuildSystem.md) · [`docs/cn/Roadmap.md`](docs/cn/Roadmap.md)

## 项目结构

```
ZirconOSAero/
├── build.zig              # Zig 构建
├── build.zig.zon          # Zig 依赖
├── run.sh                 # 构建与运行辅助脚本
├── Makefile               # Make 便捷入口（可选；主入口为 zig build）
├── assets/                # 标志与截图
├── scripts/               # 构建辅助（见 scripts/README.md）
├── gnu-efi/               # LoongArch GNU-EFI 产物（gitignore；make fetch-gnu-efi）
├── boot/
│   ├── uefi/main.zig      # UEFI ZBM（x86_64 / aarch64；LoongArch 见 main_loongarch64.zig）
│   └── zbm/               # ZBM：BIOS/MBR、BCD、菜单（Windows 7 风格）
├── link/                  # 各架构链接脚本
│   └── x86_64.ld / aarch64.ld / loongarch64.ld / riscv64.ld / mips64el.ld
├── src/                   # 内核源码
│   ├── main.zig           # 内核入口（Phase 0–11 引导路径）
│   ├── config/            # 配置解析 + 嵌入式默认（*.conf、defaults.zig）
│   ├── arch/              # 架构相关
│   │   ├── x86_64/        #   Multiboot2、分页、IDT、ISR、syscall
│   │   ├── aarch64/       #   AArch64 引导与分页
│   │   └── (loongarch64, riscv64, mips64el)
│   ├── hal/               # 硬件抽象
│   │   ├── x86_64/        #   VGA、PIC、PIT、端口 I/O、串口、GDT、framebuffer
│   │   └── aarch64/       #   GIC、定时器、PL011 UART
│   ├── drivers/           # 设备驱动
│   │   └── video/         #   VGA、HDMI、framebuffer、显示管理
│   ├── ke/                # Kernel Executive — 调度、定时器、中断、同步
│   ├── mm/                # 内存管理 — 物理帧、虚拟内存、堆
│   ├── ob/                # Object Manager — 对象、句柄表、命名空间
│   ├── ps/                # 进程子系统 — 进程与线程
│   ├── se/                # Security — 令牌、SID、访问检查
│   ├── io/                # I/O Manager — 设备、驱动、IRP
│   ├── lpc/               # LPC — 端口与消息
│   ├── rtl/               # 运行时 — 内核日志
│   ├── fs/                # 文件系统 — VFS、FAT32、NTFS
│   ├── loader/            # 加载器 — PE32/PE32+/ELF
│   ├── libs/              # 用户态 API 库
│   │   ├── ntdll.zig      #   Native API（Nt*/Rtl*/Dbg*）
│   │   └── kernel32.zig   #   Win32 基础 API
│   ├── servers/           # 系统服务
│   │   ├── server.zig     #   Process Server（PID 1）
│   │   └── smss.zig       #   Session Manager（SMSS）
│   └── subsystems/        # 子系统
│       └── win32/         #   Win32 子系统
│           ├── subsystem.zig  # csrss 服务器
│           ├── exec.zig       # Win32 执行引擎
│           ├── user32.zig     # 窗口 API
│           ├── gdi32.zig      # GDI API
│           ├── console.zig    # 控制台运行时
│           ├── cmd.zig        # CMD
│           ├── powershell.zig # ZirconShell
│           └── wow64.zig      # WOW64（见 wow64/ 子模块）
├── src/desktop/           # 桌面主题 Zig 工程；各主题含 resources/
├── src/fonts/             # 共享开源字体（make fonts / scripts/fonts/fetch-fonts.sh）
└── docs/                  # 设计文档（en/ 与 cn/）
```

## 桌面（Aero）

本仓库仅内置 **Windows 7 Aero** 壳：Zig 与静态资源在 `src/desktop/aero/`（含 `resources/`）。**合成在 CPU / framebuffer 上完成**，与完整 GPU（WDDM/D3D）管线不同；详见 [docs/cn/DesktopManagerSpec.md](docs/cn/DesktopManagerSpec.md)。

字体：`make fonts` 或 `scripts/fonts/fetch-fonts.sh` 填充 `src/fonts/`。

LoongArch UEFI 链接 GNU-EFI：`make fetch-gnu-efi`（输出在 `gnu-efi/`；见 `scripts/README.md`）。

`src/config/desktop.conf`（编译期嵌入）中 `[desktop] theme` 仅 **`aero`** 或 **`none`**（无图形壳）。

```ini
[desktop]
theme = aero
color_scheme = zircon_blue
```

## 依赖

Ubuntu/Debian（**无需** GRUB；ISO 由 xorriso + ZBM 生成）：

```bash
sudo apt update
sudo apt install -y xorriso dosfstools mtools \
    qemu-system-x86 qemu-system-arm ovmf
```

Zig：从 [ziglang.org](https://ziglang.org/download/) 安装并加入 PATH；建议使用 **0.15.2** 与 CI 一致。

## 构建与运行

```bash
# run.sh（推荐）
./run.sh build              # 内核 (Debug)
./run.sh build-release      # 内核 (Release)
./run.sh iso                # UEFI ISO（ZBM，无 GRUB；x86_64）
./run.sh run                # 按 build.conf 运行 QEMU（默认 UEFI+ZBM）
./run.sh run-debug          # ZBM MBR 磁盘 + GDB
./run.sh run-release        # Release 内核运行
./run.sh run-uefi           # 显式 UEFI+ZBM（x86_64）
./run.sh run-uefi-aarch64   # UEFI (aarch64)
./run.sh run-aarch64        # AArch64 裸机
./run.sh clean              # 清理
./run.sh help               # 帮助

# Make 快捷方式
make run
make run-debug
make clean
make help

# 直接使用 Zig
zig build -Darch=x86_64 -Ddebug=true -Denable_idt=true
```

## Phase 0–11 功能矩阵（继承上游能力）

状态以代码与契约为准；**Partial / Stub** 非「全部完成」。

| 模块 | 状态 | 说明 |
|------|------|------|
| ZBM 引导 | Done | BIOS/MBR + UEFI；Windows 7 风格文本菜单 |
| UEFI 引导 | Done | UEFI 应用，Debug/Release，Phase 0–11 横幅 |
| VGA | Done | 文本控制台 |
| 串口 | Done | COM1 |
| 物理帧分配器 | Done | 位图分配器 |
| 分页 | Done | 四级页表，恒等映射 |
| 内核堆 | Partial | Bump + 空闲链表回收 + `mm/pool` 档位；完整池化见契约矩阵 |
| Section 对象 | Stub | `NtCreateSection` / `NtMapViewOfSection` 占位（见 NT61_CONTRACT_MATRIX） |
| IPC (LPC) | Partial | 队列、端口；连接/通信端口分离雏形、`section_view_handle` 占位 |
| 系统调用 | Partial | `int 0x80` + `syscall`/`sysret`；NT 6.1 x64 SSDT 子集（Win7 SP1 索引参考；无 `0x0010_0000` 内部号）（[SyscallABI.md](docs/cn/SyscallABI.md), [ssdt_nt61.zig](src/arch/x86_64/ssdt_nt61.zig)） |
| IDT/ISR | Done | 256 向量 |
| 调度器 | Partial | 多优先级就绪队列；完整 NT 32 级与饥饿策略见契约矩阵 |
| 定时器 | Partial | PIC + PIT ~100Hz；高精度见 [TimerPrecisionRoadmap.md](docs/cn/TimerPrecisionRoadmap.md) |
| 同步 | Done | Event、mutex、semaphore、spinlock |
| Object Manager | Done | 类型、句柄表、命名空间、可等待对象 |
| Process Manager | Done | 进程/线程、Process Server |
| Session Manager | Done | SMSS、会话、子系统注册 |
| Security | Done | Token、SID、访问检查 |
| I/O Manager | Done | 设备、驱动、IRP 分发 |
| VFS | Done | 挂载点 |
| FAT32 | Done | `C:\` 上文件与目录 |
| NTFS | Done | MFT，`D:\` 上文件与目录 |
| PE32+ 加载器 | Done | 头、DLL、导入、重定位、PEB/TEB |
| PE32 加载器 | Partial | 32 位 PE + WOW64；与官方 SysWOW64/SSDT 不对齐 |
| ELF 加载器 | Done | ELF64 头、段、共享对象 |
| ntdll | Partial | Native API 子集；服务号见 SSDT 路线图 |
| kernel32 | Partial | Win32 基础 API 子集 |
| user32 | Partial | 窗口/消息/类；NC HitTest、DWM 广播子集 |
| gdi32 | Partial | DC/原语/字体/位图子集；见 `gdi32.zig` 与契约矩阵 |
| Console | Done | 控制台运行时 |
| CMD | Done | dir、cd、set、ver、systeminfo、tasklist 等 |
| ZirconShell | Partial | cmdlet 子集；非 Microsoft PowerShell / CLR |
| csrss | Partial | Win32 服务器、窗口站、桌面、GUI 分发 |
| 执行引擎 | Partial | PE 加载、DLL 绑定、生命周期 |
| WOW64 | Partial | PE32、thunk；见 `subsystems/win32/wow64/` 子模块 |
| 注册表运行时 | Partial | 内存树与若干键；RegF/hive 持久化 Planned |
| Aero / DWM（内核壳） | Partial | 脏矩形/分层与 `compositor_config_epoch`；CPU 合成与 Win7 WDDM 差异见 DesktopManagerSpec |
| 多架构 Win32 栈 | Partial | **x86_64** 为主验证路径；其余架构见各 arch 文档与 CI |

## 里程碑（路线图阶段，非「全部已完成」）

- **Phase 0** — 工具链与 QEMU 调试
- **Phase 1** — 引导与早期内核（GDT/Multiboot2/帧/堆）
- **Phase 2** — 陷阱、定时器、调度器
- **Phase 3** — 虚拟内存与用户态
- **Phase 4** — 对象、句柄、进程核心
- **Phase 5** — IPC 与系统服务（SMSS/LPC）
- **Phase 6** — I/O、文件系统（FAT32/NTFS）、驱动
- **Phase 7** — 加载器（PE32/PE32+/ELF、DLL、导入、重定位）
- **Phase 8** — Native 用户态（ntdll/kernel32、CMD、ZirconShell）
- **Phase 9** — Win32 子系统（csrss、执行引擎、PE/DLL）
- **Phase 10** — 图形（user32、gdi32、消息队列、GUI 分发）
- **Phase 11** — WOW64（PE32、thunking、32 位 PEB/TEB）

**可复现构建与发布说明**：[docs/REPRODUCE_BUILD.md](docs/REPRODUCE_BUILD.md)
