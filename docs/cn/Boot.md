# ZirconOS 启动流程

## 1. 引导路径总览

ZirconOS 支持三种引导方式，覆盖 BIOS 和 UEFI 两种固件：

| 引导路径 | 固件 | 引导器 | 说明 |
|----------|------|--------|------|
| GRUB BIOS | BIOS | GRUB | BIOS → GRUB → Multiboot2 → kernel.elf |
| GRUB UEFI | UEFI | GRUB | UEFI → GRUB → Multiboot2 → kernel.elf |
| ZBM BIOS | BIOS | ZBM | BIOS → MBR → VBR → Stage2 → kernel.elf |
| ZBM UEFI | UEFI | ZBM | UEFI → ESP → zbmfw.efi → kernel.elf |

## 2. GRUB 引导

### BIOS 模式

1. BIOS 加载 GRUB 引导扇区
2. GRUB 读取 `boot/grub/grub.cfg`
3. 以 Multiboot2 协议加载 `kernel.elf`
4. 跳转到内核入口 `_start`

### UEFI 模式

1. UEFI 固件加载 GRUB EFI 应用
2. GRUB 读取配置，加载 `kernel.elf`
3. 以 Multiboot2 协议跳转到内核

### GRUB 配置

- `boot/grub/grub.cfg`：模板文件，包含 `@VERSION@`、`@RESOLUTION@` 占位符
- `boot/grub/grub-full.cfg`：完整多主题菜单配置
- `scripts/gen_grub_cfg.py`：根据 `build.conf` 中的 `GRUB_MENU` 选项生成最终配置

菜单模式：
- `minimal`：仅 ZirconOS 基本启动项
- `all`：包含所有桌面主题的完整菜单

## 3. ZBM (ZirconOS Boot Manager) 引导

ZBM 是自研的引导管理器，支持 BIOS 和 UEFI。

### BIOS 引导链

```
BIOS
  → MBR (boot/zbm/bios/mbr.s)
    扫描分区表，加载 VBR
  → VBR (boot/zbm/bios/vbr.s)
    加载 Stage2
  → Stage2 (boot/zbm/bios/stage2.s)
    启用 A20 地址线
    E820 内存探测
    VGA 文本模式菜单
    进入保护模式
    加载 kernel.elf
    构建 Multiboot2 信息结构
    跳转到内核入口
```

### UEFI 引导链

```
UEFI 固件
  → zbmfw.efi (boot/zbm/uefi/main.zig)
    读取配置与内核文件
    显示启动菜单
    退出 Boot Services
    跳转到内核入口
```

### ZBM 核心模块 (boot/zbm/zbm.zig)

- BCD (Boot Configuration Data) 管理
- 磁盘/分区检测
- 启动菜单 UI
- 内核加载与跳转

## 4. x86_64 内核早期启动 (start.s)

这是所有引导路径汇合后的内核入口点。

### 32 位阶段

```
_start (32-bit protected mode)
  → 保存 Multiboot2 magic 和 info 指针
  → 建立 4GB identity mapping 页表 (PML4/PDPT/PD)
  → 开启 PAE (CR4.PAE)
  → 设置 IA32_EFER.LME 启用长模式
  → 开启分页 (CR0.PG)
  → 加载 64 位 GDT
  → 远跳转进入 64 位模式
```

### 64 位阶段

```
_start64 (64-bit long mode)
  → 设置段寄存器
  → 设置内核栈 (stack_top, 16KB)
  → 启用 SSE (CR0/CR4 配置)
  → 调用 kernel_main(magic, info_addr)
```

## 5. 内核初始化阶段 (Phase 0–12)

`src/main.zig` 中的 `kernel_main` 按阶段初始化系统：

### Phase 0 — 配置加载

- 加载嵌入式配置文件 (`src/config/system.conf`, `src/config/boot.conf`, `src/config/desktop.conf`)
- 解析配置参数

### Phase 1 — 核心硬件初始化

- 验证 Multiboot2 magic 值
- 初始化 GDT / TSS
- 初始化物理帧分配器（基于 Multiboot2 内存映射）
- 初始化内核堆 (512KB bump allocator)

### Phase 2 — 中断与调度

- 初始化 IDT (256 向量)
- 初始化 PIC + PIT 定时器 (~100Hz)
- 初始化调度器
- 初始化键盘/鼠标驱动
- 开启中断 (`sti`)

### Phase 3 — 虚拟内存

- 建立内核页表
- Identity mapping
- 映射 framebuffer 到内核地址空间
- 切换到新页表

### Phase 4 — 内核管理器

- 初始化 Object Manager（对象类型、命名空间）
- 初始化 Security（创建系统 Token）
- 初始化 I/O Manager（设备/驱动框架）

### Phase 5 — IPC 与系统服务

- 创建 LPC 端口：`\LPC\PsServer`, `\LPC\ObServer`, `\LPC\IoServer`
- 启动 Process Server (PID 1)
- 启动 Session Manager / SMSS (PID 2)

### Phase 6 — 驱动与文件系统

- 加载设备驱动（video / audio / input）
- 初始化 VFS
- 挂载 FAT32 文件系统 (C:\)
- 挂载 NTFS 文件系统 (D:\)
- 初始化注册表

### Phase 7 — 加载器

- 初始化 PE32/PE32+ 加载器
- 初始化 ELF 加载器
- DLL 管理器

### Phase 8 — 用户态基础

- 初始化 ntdll (Native API)
- 初始化 kernel32 (Win32 Base API)
- 初始化控制台运行时
- 初始化 CMD 命令提示符
- 初始化 PowerShell

### Phase 9 — Win32 子系统

- 启动 csrss (Win32 子系统服务器)
- 初始化 Win32 应用执行引擎

### Phase 10 — 图形子系统

- 初始化 user32 (窗口管理/消息队列)
- 初始化 gdi32 (设备上下文/绘图)
- GUI 分发

### Phase 11 — 扩展功能

- 初始化 WOW64 (32 位兼容)
- 初始化 AC97 音频驱动

### Phase 12 — 显示模式选择

根据启动参数选择显示模式：

| 模式 | 说明 |
|------|------|
| Desktop | 图形桌面环境（选择主题后启动 DWM） |
| CMD | 命令提示符文本界面 |
| Text | 纯 VGA 文本模式 |

## 6. 链接脚本

各架构使用独立的链接脚本，定义内存布局和节安排：

| 文件 | 架构 | 加载地址 |
|------|------|----------|
| `link/x86_64.ld` | x86_64 | 1MB (0x100000)，含 .multiboot2、.uefi_vector 节 |
| `link/aarch64.ld` | aarch64 | 0x40080000 |
| `link/loongarch64.ld` | LoongArch64 | `0x00200000` 起（QEMU virt 首段 RAM；见 §8） |
| `link/riscv64.ld` | RISC-V 64 | 架构特定 |
| `link/mips64el.ld` | MIPS64 LE | 架构特定 |
| `link/mbr.ld` | x86 | MBR 引导扇区 (0x7C00) |
| `link/vbr.ld` | x86 | VBR 引导扇区 |
| `link/zbm_bios.ld` | x86 | ZBM BIOS Stage2 |

## 7. Multiboot2 信息解析

内核通过 `src/arch/x86_64/boot.zig` 解析 GRUB 传递的 Multiboot2 信息：

| 标签类型 | 解析内容 |
|----------|----------|
| Memory Map | 物理内存布局 → 帧分配器 |
| Command Line | 启动参数（cmd / powershell / desktop 模式） |
| Framebuffer | 图形帧缓冲地址、分辨率、色深 |
| Boot Loader Name | 引导器名称 |

启动模式通过内核命令行参数传递：
- `mode=cmd` — 启动到命令提示符
- `mode=powershell` — 启动到 PowerShell
- `mode=desktop` — 启动到图形桌面
- `desktop=aero` / `theme=aero` — 选择 Aero 桌面壳（与构建选项一致）

## 8. LoongArch64 启动（QEMU）

### 8.1 推荐：QEMU `-kernel` 直启（默认）

- QEMU `virt` 首段 RAM 为 **0 .. 0x10000000（256MB）**。内核链接在 **`link/loongarch64.ld`** 的 **`0x00200000`**，整块映像（含大 `.bss`）落在该段内，便于 `load_elf` 映射；**不要**把内核放在 **0x80000000** 起的高物理地址：低 256MB 与高内存（`VIRT_HIGHMEM_BASE`）之间存在**空洞**，BSS 跨越空洞时会出现未映射内存、启动即非法写。
- 入口 **`crt0.S`** 在调用 `kernel_main` 前设置 **栈指针**（LoongArch LP64D 使用 `$r3` 作栈），否则首条用栈指令会访问无效地址。
- **`make run-loongarch64`**（`LOONGARCH64_QEMU_MODE=kernel`）使用 **`qemu-system-loongarch64 -kernel build/tmp/kernel.elf`**，**无需** EDK2/GRUB/ESP，**串口** `-serial stdio` 即可看到 `klog` 输出。
- **显示（kernel 模式）**：ramfb 用于图形 framebuffer。在部分 QEMU 版本中，LoongArch（与 RISC-V 类似）可能出现「Guest has not initialized the display (yet)」持续显示，即使 guest 已报告 ramfb 设置成功——此为已知的 QEMU 行为。**变通**：使用 `LOONGARCH64_QEMU_MODE=uefi`，搭配 `make build-esp` 与固件；UEFI + virtio-gpu-pci 可提供正常显示。

### 8.2 UEFI + ESP（仅 ZBM）

本仓库 **LoongArch64 不提供 GRUB 路径**；UEFI 启动仅支持 **ZBM + UEFI**（`BOOTLOADER=zbm`，Makefile 会对 `grub` 报错）。

- **标准路径**：固件查找 `\EFI\BOOT\BOOTLOONGARCH64.EFI`；缺失则进入 Shell。
- **EDK2 Shell**（`make fetch-firmware` / `fetch-loongarch-boot-efi`）可作固件内辅助或备用，**不是**主引导方案。
- **ZBM**：Zig **无法**直接 `zig build-exe -target loongarch64-uefi` 出 PE（`UnsupportedCoffArchitecture`）。使用 **`boot/zbm/uefi/main_loongarch64.zig`** → `zbm_loongarch64.o`，再经 **GNU-EFI**（`make fetch-gnu-efi` 提供 crt0/lds）与 **`objcopy --target=efi-app-loongarch64`** 得到 `BOOTLOONGARCH64.EFI`。交叉 GCC 可选，可用 **`zig cc`**；**`llvm-objcopy`** 或 **`loongarch64-linux-gnu-objcopy`** 二选一。
- **`make run-loongarch64`**（`LOONGARCH64_QEMU_MODE=uefi`）需 **`build-esp`** 与 **`QEMU_EFI.fd`**。
