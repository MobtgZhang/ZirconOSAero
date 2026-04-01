# ZirconOSAero 启动流程（仅 ZBM）

本仓库**仅**使用自研 **ZirconOSAero Boot Manager (ZBM)**。**不包含 GRUB**：`Makefile` 在 `BOOTLOADER=grub` 时会报错。内核仍解析由 ZBM（UEFI 主程序等）构造的 **Multiboot2 风格信息块**；该格式见 **Multiboot2 公开规范**，与是否安装第三方 GRUB **无关**。

## 1. 引导路径矩阵

| 架构 | 主路径 | 固件链路 | 说明 |
|------|--------|----------|------|
| **x86_64** | ZBM BIOS | BIOS → MBR → VBR → Stage2 → `kernel.elf` | Stage2 构建 Multiboot2 handoff |
| **x86_64** | ZBM UEFI | UEFI → ESP `\EFI\BOOT\BOOTX64.EFI` → `kernel.elf` | ISO：[scripts/build/mkiso-uefi-zbm.sh](../../scripts/build/mkiso-uefi-zbm.sh) |
| **aarch64** | ZBM UEFI | UEFI → ESP（如 `BOOTAA64.EFI`）→ `kernel.elf` | `zig build uefi`；`make run-aarch64` |
| **riscv64** | ZBM UEFI | UEFI → ESP `BOOTRISCV64.EFI` → `kernel.elf` | Zig 目标文件 + GNU-EFI：`make build-zbm-riscv64-uefi` |
| **loongarch64** | ZBM UEFI | UEFI → ESP `BOOTLOONGARCH64.EFI` → `kernel.elf` | `main_loongarch64.zig` + GNU-EFI：`make build-zbm-loongarch-uefi` |
| **loongarch64** | 开发旁路 | `qemu-system-loongarch64 -kernel` | **仅开发**：无 ZBM/ESP，见 §8 |

**mips64el** 视为 **experimental（试验）**；产品化验证优先上述四架构。

BCD 与 Windows 的差异说明见 [boot/zbm/README.md](../../boot/zbm/README.md)。

## 2. ESP 布局（Win7 风格命名，项目自有文件）

下表为**本项目**为接近 Windows 7 启动体验而采用的约定路径，**不是**与微软专有 BCD 仓库的二进制兼容实现。

| 路径 | 作用 |
|------|------|
| `\Boot\BCD` | 项目用简化启动配置（由 `boot/zbm/zbm.zig` 等逻辑使用） |
| `\Boot\zbm.efi` | `src/config/boot.conf` 中 `loader_path` 可选引用 |
| `\EFI\BOOT\BOOT*.EFI` | 各架构 UEFI 应用，源自 `boot/zbm/uefi/` |
| `\boot\kernel.elf` | ESP（或数据分区，视镜像脚本而定）上的内核 |

分辨率与帧缓冲默认值由根目录 **`build.conf`** 的 `RESOLUTION` 经 `make sync-resolution` 写入 `src/config/*.conf`，**不再**使用任何 GRUB 专用配置段。

## 3. ZBM（ZirconOSAero Boot Manager）

### BIOS 引导链（x86_64）

```
BIOS
  → MBR (boot/zbm/bios/mbr.s)
    扫描分区表，加载 VBR
  → VBR (boot/zbm/bios/vbr.s)
    加载 Stage2
  → Stage2 (boot/zbm/bios/stage2.s)
    启用 A20
    E820 内存探测
    VGA 文本菜单
    进入保护模式
    加载 kernel.elf
    构建 Multiboot2 信息块
    跳转到内核 _start（32 位）再进长模式
```

### UEFI 引导链

```
UEFI 固件
  → BOOT*.EFI（boot/zbm/uefi/main.zig，及架构相关入口）
    加载内核、显示菜单
    ExitBootServices
    在内存中构建 Multiboot2 handoff
    按架构约定跳转到内核入口
```

### ZBM 核心（`boot/zbm/zbm.zig`）

- 简化的 **BCD** 语义（菜单、超时、条目）——**clean-room**，**不**保证解析真实 Windows BCD 二进制
- 磁盘/分区检测
- 启动菜单 UI
- 内核加载与跳转

### UEFI 文本菜单操作（`boot/zbm/uefi/menu_common.zig`）

- **方向键**：标准 EFI 扫描码、Page Up/Down、Home/End；部分固件依赖事件，已实现 `checkEvent` + `waitForEvent` 与轮询结合。
- **字母键**：`j`/`k` 或 `w`/`s` 等价下/上。
- **数字键**：`1`–`8` 直接选中对应条目（与 `MAX_ENTRIES` 一致）。
- **限制**：若固件无 `ConIn`（仅串口等），菜单无法读键；需支持键盘的 UEFI 控制台或调整虚拟机参数。

## 4. x86_64 内核早期启动（`src/arch/x86_64/start.s`）

ZBM 递交 Multiboot2 后进入内核（magic 与 info 指针按规范在寄存器中）。

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
_start64
  → 设置段寄存器
  → 设置内核栈 (stack_top, 16KB)
  → 启用 SSE (CR0/CR4)
  → 调用 kernel_main(magic, info_addr)
```

**x86_64 UEFI 与中断**：ZBM 与 BIOS 路径均递交 **Multiboot2**。部分路径上内核仍用 **8259 PIC + PIT**；完整 ACPI RSDP / IOAPIC 迁移见内核与 HAL 文档。

## 5. 内核初始化阶段（Phase 0–12）

`src/main.zig` 中 `kernel_main` 按阶段初始化。**本节为设计说明**，各阶段成熟度不一；真实状态见 [Roadmap.md](Roadmap.md) 与根 README 的诚实标注。

（Phase 0–12 意图不变：配置、硬件、中断、虚拟内存、管理器、IPC、驱动、加载器、用户态、Win32、图形、扩展、显示模式；细节见 [Kernel.md](Kernel.md)。）

## 6. 链接脚本

| 文件 | 架构 | 加载地址 |
|------|------|----------|
| `link/x86_64.ld` | x86_64 | 1MB (0x100000)，含 `.multiboot2`、`.uefi_vector` |
| `link/aarch64.ld` | aarch64 | 0x40080000 |
| `link/loongarch64.ld` | LoongArch64 | `0x00200000` 起（QEMU virt 首段 RAM；见 §8） |
| `link/riscv64.ld` | RISC-V 64 | 架构特定 |
| `link/mips64el.ld` | MIPS64 LE | 试验性质 |
| `link/mbr.ld` | x86 | MBR (0x7C00) |
| `link/vbr.ld` | x86 | VBR |
| `link/zbm_bios.ld` | x86 | ZBM BIOS Stage2 |

## 7. Multiboot2 handoff（ZBM → 内核）

由 `src/boot/multiboot2_parse.zig` 与各架构 `boot.zig`（如 x86_64）解析。**来源**：ZBM；**格式**：公开 Multiboot2 标签布局。

| 标签类型 | 解析内容 |
|----------|----------|
| Memory Map | 物理内存布局 → 帧分配器 |
| Command Line | 启动模式、主题等 |
| Framebuffer | 帧缓冲地址、分辨率、色深（若存在） |
| Boot Loader Name | 引导器标识字符串 |

命令行示例：`mode=cmd`、`mode=desktop`、`desktop=aero` / `theme=aero`。

## 8. LoongArch64 启动（QEMU）

### 8.1 开发旁路：`-kernel`（无 ZBM）

- 内核链接在 **`0x00200000`**（`link/loongarch64.ld`），避免 BSS 跨越低/高 RAM **空洞**。
- **`make run-loongarch64`**（`LOONGARCH64_QEMU_MODE=kernel`）使用 **`qemu-system-loongarch64 -kernel build/tmp/kernel.elf`**，**无** ESP/ZBM；串口可见 `klog`。
- **非**产品引导路径，仅用于快速内核迭代。

### 8.2 产品式：UEFI + ESP + ZBM

- 固件加载 `\EFI\BOOT\BOOTLOONGARCH64.EFI`（ZBM）。本仓库**无 GRUB**。
- 构建：`make build ARCH=loongarch64` 后 `make build-zbm-loongarch-uefi`。
- **`make run-loongarch64`**（`LOONGARCH64_QEMU_MODE=uefi`）需 `build-esp` 与 `QEMU_EFI.fd`。

## 9. AArch64 与 RISC-V64（摘要）

- **AArch64**：UEFI ZBM（`boot/zbm/uefi/main.zig`），`make run-aarch64` 组合固件与 ESP。
- **RISC-V64**：`scripts/build/zbm-riscv64-efi.sh` 生成 `BOOTRISCV64.EFI`，`make build-zbm-riscv64-uefi`。
