# ZirconOS 文档（中文）

ZirconOS 是一个基于 Zig 语言实现的 **NT 风格混合微内核操作系统**。内核提供最小机制（调度、虚拟内存、IPC、中断、系统调用），复杂系统语义通过用户态服务和子系统实现，兼容 Win32 API 子集。

**英文文档**：[../README.md](../README.md) · **English pages**: [`../en/`](../en/)

## 文档目录

| 文档 | 说明 |
|------|------|
| [Architecture.md](Architecture.md) | 总体架构设计：分层模型、设计原则、对象模型、安全模型 |
| [Kernel.md](Kernel.md) | 内核内部实现：调度器、内存管理、中断、系统调用、IPC、对象管理器 |
| [Boot.md](Boot.md) | 启动流程：GRUB / ZBM / UEFI 引导路径、内核初始化阶段 (Phase 0–12) |
| [Servers.md](Servers.md) | 系统服务：Process Server、Session Manager、LPC 端口 |
| [Subsystems.md](Subsystems.md) | 子系统：Win32 (CMD/PowerShell/user32/gdi32)、WOW64、POSIX |
| [BuildSystem.md](BuildSystem.md) | 构建系统：build.conf 配置、Makefile、build.zig、run.sh 用法 |
| [Roadmap.md](Roadmap.md) | 开发路线图：里程碑 Phase 0–11、设计目标与非目标、风险分析 |

## 项目概览

```
ZirconOS/
├── src/                   # 内核源码
│   ├── main.zig           #   内核入口 (Phase 0-12)
│   ├── arch/              #   架构相关 (x86_64, aarch64, loongarch64, riscv64, mips64el)
│   ├── hal/               #   硬件抽象层 (VGA, PIC, PIT, Serial, GDT)
│   ├── ke/                #   Kernel Executive (调度, 定时, 中断, 同步)
│   ├── mm/                #   内存管理 (物理帧, 虚拟内存, 堆)
│   ├── ob/                #   对象管理器 (对象, 句柄表, 命名空间)
│   ├── ps/                #   进程子系统 (进程, 线程)
│   ├── se/                #   安全 (Token, SID, 访问检查)
│   ├── io/                #   I/O 管理器 (设备, 驱动, IRP)
│   ├── lpc/               #   IPC (LPC Port, 消息队列)
│   ├── fs/                #   文件系统 (VFS, FAT32, NTFS)
│   ├── loader/            #   加载器 (PE32, PE32+, ELF)
│   ├── drivers/           #   设备驱动 (video, audio, input)
│   ├── libs/              #   用户态 API (ntdll, kernel32)
│   ├── servers/           #   系统服务 (Process Server, SMSS)
│   ├── subsystems/win32/  #   Win32 子系统 (csrss, CMD, PowerShell, user32, gdi32)
│   ├── registry/          #   注册表
│   ├── rtl/               #   运行时库 (klog)
│   ├── config/            #   配置解析器 + 嵌入式默认 *.conf（system/boot/desktop）
│   ├── desktop/           #   桌面主题 Zig 工程（各主题含 resources/）
│   └── fonts/             #   共享开源字体（make fonts）
├── boot/                  # 引导代码 (GRUB, ZBM, UEFI)
├── link/                  # 各架构链接脚本
├── gnu-efi/               # LoongArch GNU-EFI 构建输出（gitignore）
├── scripts/               # 构建辅助脚本（见 scripts/README.md）
├── tests/                 # 测试套件
├── build.zig              # Zig 构建配置
├── Makefile               # Make 入口
└── run.sh                 # 统一构建运行脚本
```

## 核心技术栈

- **语言**: Zig（无 libc 依赖）
- **架构**: x86_64（主要）、aarch64、loongarch64、riscv64、mips64el
- **引导**: BIOS (GRUB Multiboot2) + UEFI + ZBM (自研 Boot Manager)
- **运行环境**: QEMU
