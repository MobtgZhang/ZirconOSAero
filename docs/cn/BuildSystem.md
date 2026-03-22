# ZirconOS 构建系统

## 1. 构建工具链

| 工具 | 用途 |
|------|------|
| Zig | 编译器与构建系统 (无 libc 依赖) |
| Make | 便捷构建入口，读取 `build.conf` 并调用 `zig build` |
| GRUB | 生成可启动 ISO |
| QEMU | 虚拟机运行环境 |
| xorriso / mtools | ISO 镜像制作工具 |

## 2. 构建配置 (build.conf)

`build.conf` 是持久化的构建配置文件，控制构建产物的变体。

### 配置项

| 配置项 | 可选值 | 默认值 | 说明 |
|--------|--------|--------|------|
| `ARCH` | x86_64, aarch64, loongarch64, riscv64, mips64el | x86_64 | 目标架构 |
| `BOOT_METHOD` | mbr, uefi | uefi | 启动方式 |
| `BOOTLOADER` | zbm | zbm | 引导加载器（本仓库仅 ZBM） |
| `DESKTOP` | aero, none | aero | 桌面壳（仅 Aero） |
| `OPTIMIZE` | Debug, ReleaseSafe, ReleaseFast, ReleaseSmall | Debug | 优化级别 |
| `RESOLUTION` | 宽x高x色深 | 1024x768x32 | 显示分辨率 |
| `QEMU_MEM` | 内存大小 | 512M | QEMU 分配内存（x86 等） |
| `QEMU_MEM_LOONGARCH64` | 内存大小 | 1536M | `make run-loongarch64` 专用；`qemu-system-loongarch64 -M virt` 要求 **大于 1G** |
| `LOONGARCH64_FIRMWARE_DIR` | 目录 | `~/Firmware/LoongArchVirtMachine` | 内含 `QEMU_EFI.fd` / `QEMU_VARS.fd`；若不存在则回退到 `firmware/` 下 EDK2 nightly 文件名 |
| `LOONGARCH64_BOOT_EFI` | 文件 | （自动探测） | 若存在 `BOOTLOONGARCH64.EFI`（置于上述目录或 `firmware/`），会写入 ESP 的 `\EFI\BOOT\`；否则需在 Shell 中手动链式加载内核 |
| `ENABLE_IDT` | true, false | true | 是否启用 IDT |
| `DEBUG_LOG` | true, false | true | 是否启用调试日志 |
| `GRUB_MENU` | all, minimal | minimal | GRUB 菜单模式 |

### 覆盖配置

配置可通过环境变量或 make 参数覆盖：

```bash
make DESKTOP=aero BOOT_METHOD=uefi BOOTLOADER=zbm
```

### 交互式配置

使用 `scripts/configure.py` 进行交互式配置：

```bash
python3 scripts/configure.py
```

## 3. 构建调用链

```
run.sh / make 命令
    │
    ├─ 读取 build.conf
    │
    ├─ scripts/gen_grub_cfg.py (生成 GRUB 配置)
    │
    └─ zig build -Darch=... -Ddebug=... -Denable_idt=...
        │
        ├─ 编译内核 → build/tmp/kernel.elf
        ├─ 编译 UEFI 应用 → zirconos.efi (若 UEFI)
        ├─ 编译 ZBM → MBR/VBR/Stage2 (若 ZBM)
        └─ 生成 ISO → build/release/zirconos-1.0.0-{arch}.iso
```

## 4. 使用 run.sh (推荐)

`run.sh` 是统一的构建运行脚本入口。

### 构建命令

```bash
./run.sh build              # 构建内核 (Debug)
./run.sh build-release      # 构建内核 (Release)
./run.sh iso                # 构建 ISO 镜像
./run.sh clean              # 清理构建产物
./run.sh help               # 查看帮助
```

### 运行命令

```bash
./run.sh run                # BIOS 模式运行
./run.sh run-debug          # BIOS + GDB 调试服务器
./run.sh run-release        # BIOS Release 模式
./run.sh run-uefi           # UEFI 模式运行 (x86_64)
./run.sh run-uefi-aarch64   # UEFI 模式运行 (aarch64)
./run.sh run-aarch64        # AArch64 裸机运行
```

## 5. 使用 Make

Make 提供简洁的构建入口：

```bash
make run                    # 等同于 ./run.sh run
make run-debug              # 等同于 ./run.sh run-debug
make clean                  # 等同于 ./run.sh clean
make help                   # 查看帮助

# 覆盖参数
make run BOOTLOADER=zbm BOOT_METHOD=mbr
make run DESKTOP=aero ARCH=x86_64
```

## 6. 直接使用 Zig

```bash
zig build -Darch=x86_64 -Ddebug=true -Denable_idt=true
```

## 7. 构建产物

| 产物 | 路径 | 说明 |
|------|------|------|
| 内核 ELF | `build/tmp/kernel.elf` | Multiboot2 内核映像 |
| UEFI 应用 | `zirconos.efi` | UEFI 启动应用 |
| ZBM MBR | `build/tmp/mbr.bin` | ZBM 主引导记录 |
| ZBM VBR | `build/tmp/vbr.bin` | ZBM 卷引导记录 |
| ZBM Stage2 | `build/tmp/stage2.bin` | ZBM 第二阶段加载器 |
| ISO 镜像 | `build/release/zirconos-1.0.0-{arch}.iso` | 可启动 ISO |

## 8. 系统配置文件

默认配置位于 `src/config/`，编译时通过 `@embedFile` 嵌入内核：

| 文件 | 说明 |
|------|------|
| `src/config/system.conf` | 系统核心参数：主机名、内存、调度策略、显示、文件系统 |
| `src/config/boot.conf` | 引导配置：超时、Multiboot 参数、UEFI/ZBM 选项 |
| `src/config/desktop.conf` | 桌面环境：主题选择、DWM 配置、任务栏、字体 |
| `src/config/defaults.zig` | `@embedFile` 加载上述 .conf |

`src/config/config.zig` 负责在运行时解析这些配置并提供访问接口。

## 9. 依赖安装

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y grub-pc-bin grub-common xorriso mtools \
    qemu-system-x86 qemu-system-arm ovmf
```

### Zig 编译器

从 [ziglang.org](https://ziglang.org/download/) 下载并加入 PATH。

## 10. 桌面主题与字体

主题源码与 `resources/` 位于 `src/desktop/aero/`。

开源字体需按需下载到 `src/fonts/`：

```bash
make fonts
# 或: ./scripts/fonts/fetch-fonts.sh
```

## 11. 测试

```bash
# 运行全部测试
python3 tests/run_all.py

# 单独测试
python3 tests/test_build_config.py      # 构建配置测试
python3 tests/test_boot_combinations.py  # 启动组合测试
```

## 12. 调试

### GDB 调试

```bash
./run.sh run-debug
# 另一个终端
gdb build/tmp/kernel.elf
(gdb) target remote :1234
(gdb) break kernel_main
(gdb) continue
```

### 串口日志

启用 `DEBUG_LOG=true` 后，内核通过 COM1 串口输出日志。QEMU 默认将串口重定向到终端。
