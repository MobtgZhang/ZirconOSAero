# ZirconOS v1.0

**ZirconOS** 是一个 NT 风格混合微内核操作系统，使用 Zig 语言实现，支持 BIOS (GRUB Multiboot2) 和 UEFI 启动。

**商标与独立性**：本项目不是 Microsoft 产品；「Windows」等商标归各自所有者。第三方与字体许可见仓库根目录 [THIRD_PARTY.md](THIRD_PARTY.md)。

<p align="center">
  <img src="assets/ZirconOS_logo.svg" alt="ZirconOS 标志" width="480" />
</p>

## 截图

<p align="center">
  <img src="assets/screenshot-zbm.png" alt="ZBM 引导管理器" width="70%" />
</p>
<p align="center"><em>ZirconOS Boot Manager (ZBM) — Windows 7 风格文本菜单</em></p>

<p align="center">
  <img src="assets/screenshot-aero.png" alt="ZirconOS Aero 桌面" width="70%" />
</p>
<p align="center"><em>唯一内置桌面：Windows 7 Aero（NT 6.1）</em></p>

<p align="center">
  <img src="assets/screenshot-cmd.png" alt="CMD 命令提示符" width="70%" />
</p>
<p align="center"><em>CMD 命令提示符</em></p>

**English**: [README.md](README.md)

## 设计理念

- **NT 风格混合微内核**：内核提供调度、虚拟内存、IPC、中断、系统调用等核心机制
- **用户态系统服务**：Object Manager、Process Manager、I/O Manager、Security 等作为服务运行
- **Win32 兼容层**：ntdll + kernel32 + kernelbase + 控制台子系统
- **Win32 子系统服务器**：csrss 风格的子系统管理、窗口站、桌面
- **Win32 应用执行引擎**：PE 加载 + DLL 绑定 + 进程创建 + API dispatch
- **图形子系统**：user32 (窗口/消息) + gdi32 (绘图/字体/位图)
- **WOW64 兼容层**：PE32 加载 + 32→64 位 syscall thunking + 32 位 PEB/TEB
- **双 Shell 环境**：CMD 命令提示符 + PowerShell 高级 Shell
- **双文件系统**：FAT32 (系统分区) + NTFS (数据分区)
- **多架构支持**：x86_64（主要）、aarch64、loongarch64、riscv64、mips64el

设计文档：[`docs/README.md`](docs/README.md) · [`docs/cn/README.md`](docs/cn/README.md) · [`docs/cn/Architecture.md`](docs/cn/Architecture.md) · [`docs/cn/Kernel.md`](docs/cn/Kernel.md) · [`docs/cn/Boot.md`](docs/cn/Boot.md) · [`docs/cn/Servers.md`](docs/cn/Servers.md) · [`docs/cn/Subsystems.md`](docs/cn/Subsystems.md) · [`docs/cn/BuildSystem.md`](docs/cn/BuildSystem.md) · [`docs/cn/Roadmap.md`](docs/cn/Roadmap.md)

## 项目结构

```
ZirconOS/
├── build.zig              # Zig 构建配置
├── build.zig.zon          # Zig 依赖声明
├── run.sh                 # 构建与运行脚本
├── Makefile               # Make 便捷入口
├── assets/                # 标志与截图
├── scripts/               # 构建辅助脚本（见 scripts/README.md）
├── gnu-efi/               # LoongArch GNU-EFI 构建产物（gitignore，make fetch-gnu-efi）
├── boot/
│   ├── grub/grub.cfg      # GRUB 引导配置 (系统选择菜单)
│   ├── uefi/main.zig      # UEFI 启动应用
│   └── zbm/               # ZirconOS Boot Manager (BIOS/MBR/GPT)
├── link/                  # 各架构链接脚本
│   └── x86_64.ld / aarch64.ld / loongarch64.ld / riscv64.ld / mips64el.ld
├── src/                   # 内核源码
│   ├── main.zig           # 内核入口 (Phase 0-11 启动流程)
│   ├── config/            # 配置解析器 + 嵌入式默认配置（*.conf、defaults.zig）
│   ├── arch/              # 架构相关代码
│   │   ├── x86_64/        #   Multiboot2, 分页, IDT, ISR, Syscall
│   │   ├── aarch64/       #   AArch64 启动, 分页
│   │   └── (loongarch64, riscv64, mips64el)
│   ├── hal/               # 硬件抽象层
│   │   ├── x86_64/        #   VGA, PIC, PIT, Port I/O, Serial, GDT, Framebuffer
│   │   └── aarch64/       #   GIC, Timer, PL011 UART
│   ├── drivers/           # 设备驱动
│   │   └── video/         #   VGA, HDMI, Framebuffer, Display Manager
│   ├── ke/                # Kernel Executive - 调度, 定时, 中断, 同步
│   ├── mm/                # Memory Manager - 物理帧分配, 虚拟内存, 堆
│   ├── ob/                # Object Manager - 对象/句柄表/命名空间
│   ├── ps/                # Process Subsystem - 进程/线程管理
│   ├── se/                # Security - Token/SID/访问检查
│   ├── io/                # I/O Manager - 设备/驱动/IRP
│   ├── lpc/               # LPC - IPC 消息传递/Port
│   ├── rtl/               # Runtime Library - 内核日志
│   ├── fs/                # File Systems - VFS/FAT32/NTFS
│   ├── loader/            # Loader - PE32/PE32+/ELF
│   ├── libs/              # 用户态 API 库
│   │   ├── ntdll.zig      #   Native API (Nt*/Rtl*/Dbg*)
│   │   └── kernel32.zig   #   Win32 Base API
│   ├── servers/           # 系统服务
│   │   ├── server.zig     #   Process Server (PID 1)
│   │   └── smss.zig       #   Session Manager (SMSS)
│   └── subsystems/        # 子系统实现
│       └── win32/         #   Win32 子系统
│           ├── subsystem.zig  csrss 子系统服务器
│           ├── exec.zig       Win32 应用执行引擎
│           ├── user32.zig     窗口/消息 API
│           ├── gdi32.zig      图形设备接口 API
│           ├── console.zig    控制台运行时
│           ├── cmd.zig        CMD 命令提示符
│           ├── powershell.zig PowerShell
│           └── wow64.zig      WOW64 32位兼容层
├── src/desktop/           # 各主题 Zig 工程；每主题含 `resources/`（壁纸/图标等）
├── src/fonts/             # 全主题共享开源字体（make fonts / scripts/fonts/fetch-fonts.sh）
└── docs/                  # 设计文档（en/ 英文 · cn/ 中文）
```

## 桌面（Aero）

**ZirconOSAero** 仅内置 **Windows 7 Aero** 壳：源码与资源在 `src/desktop/aero/`（含 `resources/`）。

字体：`make fonts` 或 `scripts/fonts/fetch-fonts.sh` 下载到 `src/fonts/`。

LoongArch UEFI 链接依赖的 GNU-EFI：`make fetch-gnu-efi`（输出到 `gnu-efi/`，见 `scripts/README.md`）。

`src/config/desktop.conf` 中 `[desktop] theme` 仅 **`aero`** 或 **`none`**。

```ini
[desktop]
theme = aero
color_scheme = zircon_blue
```

## 依赖

Ubuntu/Debian：

```bash
sudo apt update
sudo apt install -y grub-pc-bin grub-common xorriso mtools \
    qemu-system-x86 qemu-system-arm ovmf
```

Zig 编译器：从 [ziglang.org](https://ziglang.org/download/) 下载并加入 PATH。

## 构建与运行

```bash
# 使用 run.sh（推荐）
./run.sh build              # 构建内核 (Debug)
./run.sh build-release      # 构建内核 (Release)
./run.sh iso                # 构建 ISO
./run.sh run                # 构建 ISO 并在 QEMU 中运行 (BIOS)
./run.sh run-debug          # BIOS + GDB 调试服务器
./run.sh run-release        # BIOS Release 模式
./run.sh run-uefi           # UEFI 模式运行 (x86_64)
./run.sh run-uefi-aarch64   # UEFI 模式运行 (aarch64)
./run.sh run-aarch64        # AArch64 裸机运行
./run.sh clean              # 清理构建产物
./run.sh help               # 查看帮助

# 使用 Make（简洁入口）
make run                    # 等同于 ./run.sh run
make run-debug              # 等同于 ./run.sh run-debug
make clean                  # 等同于 ./run.sh clean
make help                   # 查看帮助

# 使用 Zig 直接构建
zig build -Darch=x86_64 -Ddebug=true -Denable_idt=true
```

## v1.0 功能矩阵 (Phase 0-11)

完成度与 [NT61_CONTRACT_MATRIX.md](docs/cn/NT61_CONTRACT_MATRIX.md) 交叉引用；**部分 / 占位 / 计划** 表示非「完成」。

| 模块 | 状态 | 说明 |
|------|------|------|
| ZBM Boot | 完成 | BIOS/MBR + UEFI；Windows 7 风格菜单（本仓库无 GRUB） |
| UEFI Boot | 完成 | UEFI 应用, Debug/Release |
| VGA Output | 完成 | 文本模式控制台 |
| Serial | 完成 | COM1 |
| Frame Allocator | 完成 | 位图物理帧分配器 |
| Paging | 完成 | 四级页表 |
| Kernel Heap | 部分 | Bump + `mm/pool` NonPaged 档位 |
| Section 对象 | 占位 | `NtCreateSection` / `NtMapViewOfSection` 未实现 |
| IPC (LPC) | 部分 | 队列与端口；连接监听端口、`section_view_handle` 占位 |
| Syscall | 部分 | `int 0x80` + x86_64 `syscall`；非 Windows SSDT 索引 |
| IDT/ISR | 完成 | 256 vectors |
| Scheduler | 部分 | 优先级内轮转 |
| Timer | 部分 | PIT ~100Hz；高精度见 [TimerPrecisionRoadmap.md](docs/cn/TimerPrecisionRoadmap.md) |
| Sync | 完成 | Event, Mutex, Semaphore, SpinLock |
| Object Manager | 完成 | 句柄表、命名空间 |
| Process Manager | 完成 | 进程/线程 |
| Session Manager | 完成 | SMSS |
| Security | 完成 | Token, SID |
| I/O Manager | 完成 | 设备/IRP |
| VFS | 完成 | 挂载点 |
| FAT32 | 完成 | C:\ |
| NTFS | 完成 | D:\ |
| PE32+ Loader | 完成 | PE32+ |
| PE32 Loader | 部分 | WOW64 与官方 SysWOW64 路径不对齐 |
| ELF Loader | 完成 | ELF64 |
| ntdll | 部分 | Native API 子集 |
| kernel32 | 部分 | Win32 子集 |
| user32 | 部分 | NC HitTest、DWM 广播子集 |
| gdi32 | 部分 | 区域/路径/字体分阶段 |
| Console / CMD / PowerShell | 完成 | 见各模块 |
| csrss / Exec | 部分 | 子系统服务器与执行引擎子集 |
| WOW64 | 部分 | 见 [SSDT_Roadmap.md](docs/cn/SSDT_Roadmap.md) |
| 注册表 | 部分 | 内存树；RegF 持久化 **计划** |
| Aero 内核壳 | 部分 | 脏区策略、`compositor_config_epoch` trace |
| 多架构说明 | 必读 | [PROCESS_NT61.md](docs/cn/PROCESS_NT61.md) 二进制边界 |
| Win32k 架构 | 备忘 | [Win32kArchitectureNotes.md](docs/cn/Win32kArchitectureNotes.md) |

## 里程碑

- **Phase 0** ✅ 工具链 + QEMU 调试环境
- **Phase 1** ✅ Boot + Early Kernel (GDT/Multiboot2/Frame/Heap)
- **Phase 2** ✅ Trap / Timer / Scheduler
- **Phase 3** ✅ VM + User Mode (页表/地址空间)
- **Phase 4** ✅ Object / Handle / Process Core
- **Phase 5** ✅ IPC + System Services (SMSS/LPC)
- **Phase 6** ✅ I/O + File System (FAT32/NTFS) + Driver
- **Phase 7** ✅ Loader (PE32/PE32+/ELF, DLL管理, 导入解析, 重定位)
- **Phase 8** ✅ Native Userland (ntdll/kernel32 完整API/CMD/PowerShell)
- **Phase 9** ✅ Win32 Subsystem (csrss/exec引擎/应用执行/DLL绑定)
- **Phase 10** ✅ Graphical Subsystem (user32窗口管理/gdi32绘图/消息队列/GUI分发)
- **Phase 11** ✅ WOW64 (PE32加载/syscall thunking/32位PEB-TEB/兼容性测试)
