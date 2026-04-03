# ZirconOSAero（NT 6.1 目标）

**ZirconOSAero** 以 **NT 6.1（Windows 7）** ABI/体验为目标，独立 clean-room 实现；Aero 桌面、**仅 ZBM 引导**（BIOS/MBR 与 UEFI）。**不复制 Windows/ReactOS 源码**。

**独立项目声明**：非 Microsoft 产品；「Windows」「Windows 7」等为商标说明。第三方与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。

<p align="center">
  <img src="assets/ZirconOS_logo.svg" alt="ZirconOSAero" width="480" />
</p>

## 截图

<table width="100%">
  <tr>
    <td align="center" width="33%" valign="top">
      <img src="assets/screenshot-zbm.png" alt="ZBM 引导管理器" width="95%" /><br />
      <sub>ZBM — Windows 7 风格文本菜单</sub>
    </td>
    <td align="center" width="34%" valign="top">
      <img src="assets/screenshot-aero.png" alt="ZirconOSAero Aero 桌面" width="95%" /><br />
      <sub>Shell — Windows 7 Aero（NT 6.1）</sub>
    </td>
    <td align="center" width="33%" valign="top">
      <img src="assets/screenshot-cmd.png" alt="CMD 命令提示符" width="95%" /><br />
      <sub>CMD shell</sub>
    </td>
  </tr>
</table>

**English**: [README.md](README.md)

[![CI](https://github.com/MobtgZhang/ZirconOSAero/actions/workflows/ci.yml/badge.svg)](https://github.com/MobtgZhang/ZirconOSAero/actions/workflows/ci.yml)

**CI / 本地**：`zig build test`；`bash scripts/ci-qemu-smoke.sh`；多架构编译与 SMP/AHCI 烟测步骤见 [docs/cn/BUILD_SMOKE.md](docs/cn/BUILD_SMOKE.md)。Zig **0.15.2**（见 [docs/REPRODUCE_BUILD.md](docs/REPRODUCE_BUILD.md)、[.github/workflows/ci.yml](.github/workflows/ci.yml)）。测试索引：[docs/cn/MVT_NT61.md](docs/cn/MVT_NT61.md)。

## 设计理念

- **NT 风格混合微内核**：调度、虚拟内存、IPC、中断与系统调用在内核中实现
- **用户态系统服务**：Object Manager、Process Manager、I/O Manager、Security 等
- **Win32 兼容层**（**子集**，按里程碑推进）：**二进制兼容**指 **自研合成 DLL** + 公开文档 ABI **子集** + PE 加载策略（导出清单见 `src/config/nt61_core_dll_abi_inventory.zig` 等），**非**可在商业 Windows 上替换 `System32` 闭源微软 DLL 或与之逐位等价 — 见 [NT61_CONTRACT_MATRIX.md](docs/cn/NT61_CONTRACT_MATRIX.md)、[API_COMPAT_MATRIX.md](docs/cn/API_COMPAT_MATRIX.md)、[BINARY_COMPAT_GAP_AUDIT.md](docs/cn/BINARY_COMPAT_GAP_AUDIT.md)
- **Win32 子系统服务器**（**部分**）：csrss 风格进程注册与消息桥接；完整窗口站/桌面生命周期分阶段 — [LPC_NT61_HANDSHAKE.md](docs/cn/LPC_NT61_HANDSHAKE.md)
- **Win32 执行引擎**（**子集**）：PE 加载、DLL 绑定、进程创建、API 分发（仅已支持路径）
- **图形子系统**（**部分**）：user32（窗口/消息）与 gdi32（绘图/字体/位图），优先 Aero/壳场景 — **非**完整 GDI（ROP、完整字体光栅化、完整 DC 对象模型）
- **WOW64**（**部分**）：PE32 加载、32→64 syscall thunk、已实现的 32 位 PEB/TEB；可测子集与双表维护见 [PHASE_G_WOW64.md](docs/cn/PHASE_G_WOW64.md)；完整 SysWOW64 另见 [延后表面](docs/cn/NT61_DEFERRED_SURFACES.md)
- **文本 Shell**：内核内为 **CMD**；脚本类宿主计划为 **用户态 .NET**（不在本仓库内核实现）
- **双文件系统**：FAT32（系统卷）与 NTFS（数据卷）
- **多架构**：x86_64（主路径）、aarch64、loongarch64、riscv64、mips64el

**流程与契约（必读）**：[docs/cn/PROCESS_NT61.md](docs/cn/PROCESS_NT61.md) · [docs/cn/NT61_CONTRACT_MATRIX.md](docs/cn/NT61_CONTRACT_MATRIX.md)（与下方矩阵 **Status** 同源；**Partial / Stub** 即非 Done）· [docs/cn/NT61_DEFERRED_SURFACES.md](docs/cn/NT61_DEFERRED_SURFACES.md) · [docs/cn/DWM_NOTIFY_MODEL_NT61.md](docs/cn/DWM_NOTIFY_MODEL_NT61.md) · [docs/cn/MVT_NT61.md](docs/cn/MVT_NT61.md) · [docs/en/COPYRIGHT_AND_SOURCES.md](docs/en/COPYRIGHT_AND_SOURCES.md) / [docs/cn/COPYRIGHT_AND_SOURCES.md](docs/cn/COPYRIGHT_AND_SOURCES.md)

状态标签：`Stub` · `Partial` · `Done` · `Verified`。API 覆盖：[docs/cn/API_COMPAT_MATRIX.md](docs/cn/API_COMPAT_MATRIX.md)。

更多：[`docs/README.md`](docs/README.md) · [`docs/cn/README.md`](docs/cn/README.md) · [`docs/cn/Architecture.md`](docs/cn/Architecture.md) · [`docs/cn/Kernel.md`](docs/cn/Kernel.md) · [`docs/cn/Boot.md`](docs/cn/Boot.md) · [`docs/cn/BuildSystem.md`](docs/cn/BuildSystem.md) · [`docs/cn/Roadmap.md`](docs/cn/Roadmap.md)

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
│   └── zbm/               # ZBM：BIOS/MBR、BCD、菜单；UEFI 源在 zbm/uefi/（main.zig / main_riscv64.zig / main_loongarch64.zig）
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

Ubuntu/Debian（ISO 由 xorriso + ZBM 生成）：

```bash
sudo apt update
sudo apt install -y xorriso dosfstools mtools \
    qemu-system-x86 qemu-system-arm ovmf
```

Zig：从 [ziglang.org](https://ziglang.org/download/) 安装并加入 PATH；`build.zig.zon` 要求 **0.15.0+**，CI 锁定 **0.15.2**。缺 Aero 壁纸 PNG 时先执行 `bash scripts/fetch-assets.sh` 或 `make fetch-assets`。

## 构建与运行

```bash
# run.sh（推荐）
./run.sh build              # 内核 (Debug)
./run.sh build-release      # 内核 (Release)
./run.sh iso                # UEFI ISO（ZBM；x86_64）
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

## 完成度说明（与 [README.md](README.md) 一致）

Clean-room；矩阵 **Done** = 烟测主路径可演示且与 [契约矩阵](docs/cn/NT61_CONTRACT_MATRIX.md) 一致，**不等于**商业 Windows 7。以矩阵、[MVT_NT61.md](docs/cn/MVT_NT61.md) 与 `zig build test` 为准。多架构 CI 与引导见 [Boot.md](docs/cn/Boot.md)。

## Phase 0–11 功能矩阵（继承上游能力）

状态以代码与契约为准；**Partial / Stub** 非「全部完成」。

| 模块 | 状态 | 说明 |
|------|------|------|
| ZBM 引导 | Done | BIOS/MBR + UEFI；Windows 7 风格文本菜单 |
| UEFI 引导 | Done | UEFI 应用，Debug/Release，Phase 0–11 横幅 |
| VGA | Done | 文本控制台 |
| 串口 | Done | COM1 |
| 物理帧分配器 | Partial | 位图 + mmap 过滤；伙伴连续页见 `phys_buddy.zig`（契约矩阵 §0） |
| 分页 | Partial | 四级表、恒等映射；每进程 CR3/SMEP 见契约矩阵 |
| 内核堆 | Partial | Bump 快路径 + 空闲链表 + `mm/pool` 档位；路径见 [MM_ALLOC_PATHS.md](docs/cn/MM_ALLOC_PATHS.md)；契约矩阵 §0 |
| Section 对象 | Partial | 匿名节 + `ntdll`/`section.zig`；syscall 分发节区 API（[MM_Section_Roadmap.md](docs/cn/MM_Section_Roadmap.md)） |
| IPC (LPC) | Partial | 队列、端口；连接/通信端口分离雏形、`section_view_handle` 占位 |
| 系统调用 | Partial | `int 0x80` + `syscall`/`sysret`（启动链见 [SyscallABI.md](docs/cn/SyscallABI.md)）；SSDT 含 `NtCreateProcess`、`NtCreateUserProcess`（**0xAA**，ZOA 参数块见 [PHASE_F_PROCESS_CREATE.md](docs/cn/PHASE_F_PROCESS_CREATE.md)）、`NtWaitForMultipleObjects`（**0x57**）、`NtDeviceIoControlFile`（**0x52**）、Lock/Unlock VM（**0x53/0x54**）等；`NtQuerySystemInformation` 多类子集 + `probe`；**ssdt_stub_parity**；阶段 E 见 [PHASE_E_NATIVE_API.md](docs/cn/PHASE_E_NATIVE_API.md) |
| IDT/ISR | Done | 256 向量 |
| 调度器 | Partial | 多优先级就绪队列；完整 NT 32 级与饥饿策略见契约矩阵 |
| 定时器 | Partial | PIC + PIT ~100Hz；高精度见 [TimerPrecisionRoadmap.md](docs/cn/TimerPrecisionRoadmap.md) |
| 同步 | Partial | 内核 `ke/sync.zig` 有 Event/Mutex/Semaphore/SpinLock；**ntdll 句柄路径**：`NtCreateEvent`/`NtWait`/`NtSetEvent`（含手动/自动复位）与 `ObjectHeader` 等待队列一致；`NtCreateMutant`/`NtReleaseSemaphore` 等仍为桩 — 见 [SCHEDULER_API.md](docs/cn/SCHEDULER_API.md)、契约矩阵 §2 |
| Object Manager | Partial | 类型、句柄表、命名空间子集；主机测试 [zircon_host_ob_test.zig](src/zircon_host_ob_test.zig) |
| Process Manager | Partial | 进程/线程、Process Server；CR3/隔离见契约矩阵 §0 |
| Session Manager | Done | SMSS、会话、子系统注册 |
| Security | Done | Token、SID、访问检查 |
| I/O Manager | Partial | 设备、驱动、`IoCompleteRequest` 与 VFS IRP；PCI 早期见 `acpi_pci_early.zig` |
| VFS | Partial | 挂载点；完整语义见契约矩阵 |
| FAT32 | Partial | `C:\` 主路径；与 NT 格式化完全互操作非目标 |
| NTFS | Partial | MFT 子集与基本路径；**非**完整 NTFS（日志/压缩等见路线图） |
| PE32+ 加载器 | Partial | 头、导入、重定位、PEB/TEB 子集；与 SSDT 持续对齐 |
| PE32 加载器 | Partial | 32 位 PE + WOW64；与官方 SysWOW64/SSDT 不对齐 |
| ELF 加载器 | Partial | ELF64 头与加载子集；glibc 动态全兼容非目标 |
| ntdll | Partial | Native API 子集；含 `RtlVerifyVersionInfo`（`os_version` 驱动）；服务号见 SSDT 路线图 |
| kernel32 | Partial | Win32 基础 API 子集 |
| user32 | Partial | 窗口/消息/类；NC HitTest、DWM 广播子集；**下阶段跟踪**：[PHASE_D_WIN32_MSG_PUMP_DWM.md](docs/cn/PHASE_D_WIN32_MSG_PUMP_DWM.md)（消息泵与 DWM/LPC 详尽待办） |
| gdi32 | Partial | DC/原语/字体/位图子集；见 `gdi32.zig` 与契约矩阵 |
| Console | Done | 控制台运行时 |
| CMD | Done | dir、cd、set、ver、systeminfo、tasklist 等 |
| .NET Shell（用户态，预留） | Planned | 内核 ZirconShell 已移除；由未来 .NET 用户态提供 |
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
- **Phase 8** — Native 用户态（ntdll/kernel32、CMD）
- **Phase 9** — Win32 子系统（csrss、执行引擎、PE/DLL）
- **Phase 10** — 图形（user32、gdi32、消息队列、GUI 分发）
- **Phase 11** — WOW64（PE32、thunking、32 位 PEB/TEB）

**可复现构建与发布说明**：[docs/REPRODUCE_BUILD.md](docs/REPRODUCE_BUILD.md)
