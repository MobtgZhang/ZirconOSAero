# ZirconOSAero 构建系统

**主入口**：`zig build` / `zig build test`。CI 锁定的 Zig 版本见 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) 与 [.github/workflows/ci.yml](../../.github/workflows/ci.yml)。`Makefile`、`build.conf` 为可选封装。

## 1. 构建工具链

| 工具 | 用途 |
|------|------|
| Zig | 编译器与构建系统 (无 libc 依赖) |
| Make | 便捷构建入口，读取 `build.conf` 并调用 `zig build` |
| ZBM | 自研引导（BIOS/MBR + UEFI） |
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
| `RESOLUTION` | 宽x高x色深 | 见 `Makefile` / `build.conf` | **`make build`** 会运行 **`scripts/sync_resolution_config.py`**，同步 **`src/config/desktop.conf`**、**`src/config/boot.conf`**、**`src/config/system.conf`**（`[display]`）、**`build/tmp/zircon_pref_fb.h`**、**`kernel_pref_fb_wh.txt`**。LoongArch 上 GOP 与 ramfb 说明见 [AeroDesktopRuntime.md](AeroDesktopRuntime.md) 小节 4.2.1.1。 |
| `QEMU_MEM` | 内存大小 | 512M | QEMU 分配内存（x86 等）。**4K + 双/三缓冲 + VirtIO scanout** 时帧缓冲与离屏占用显著增大（另见 `core/framebuffer.zig` 的 `BACK_BUF_MAX` 与 [SOFTWARE_COMPOSITOR_WDDM.md](SOFTWARE_COMPOSITOR_WDDM.md)）；日常开发可用 `build.conf` 默认 **8G**，smoke 亦不宜过小。 |
| `QEMU_GTK_ZOOM` | gtk 子选项 | zoom-to-fit=on | 默认缩放客体画面至窗口；**1:1 像素**：`make run-qemu-1to1` 或 `QEMU_GTK_ZOOM=zoom-to-fit=off`（见 [AeroDesktopRuntime.md](AeroDesktopRuntime.md) §4.2.2） |
| `QEMU_MEM_LOONGARCH64` | 内存大小 | 1536M | `make run-loongarch64` 专用；`qemu-system-loongarch64 -M virt` 要求 **大于 1G** |
| `LOONGARCH64_FIRMWARE_DIR` | 目录 | `~/Firmware/LoongArchVirtMachine` | 内含 `QEMU_EFI.fd` / `QEMU_VARS.fd`；若不存在则回退到 `firmware/` 下 EDK2 nightly 文件名 |
| `LOONGARCH64_BOOT_EFI` | 文件 | （自动探测） | 若存在 `BOOTLOONGARCH64.EFI`（置于上述目录或 `firmware/`），会写入 ESP 的 `\EFI\BOOT\`；否则需在 Shell 中手动链式加载内核 |
| `ENABLE_IDT` | true, false | true | 是否启用 IDT |
| `DEBUG_LOG` | true, false | true | 是否启用调试日志 |

### QEMU UEFI（AArch64 / RISC-V64）

- **启动路径**：EDK2 固件 → 带 ZBM 的 FAT ESP → `\boot\kernel.elf` → Multiboot2 递交 `kernel_main`。
- **命令**：需要时先 `make fetch-firmware`，再 `make run-aarch64` 或 `make run-riscv64`；两目标会在子 make 中按架构执行 `build-esp`，QEMU 使用固定的 `build/esp-aarch64.img` 或 `build/esp-riscv64.img`（Makefile 中 `ESP_IMG_AARCH64` / `ESP_IMG_RISCV64`）。
- **Zig**：`zig build -Darch=aarch64` / `-Darch=riscv64` 仅编译内核与引导相关产物；**不**负责 pflash、`-bios` 或 QEMU 启动，完整 UEFI 环境以 Make 为准。

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
    ├─ scripts/sync_resolution_config.py（RESOLUTION / make sync-resolution 时）
    │
    └─ zig build -Darch=... -Ddebug=... -Denable_idt=...
        │
        ├─ 编译内核 → build/tmp/kernel.elf
        ├─ ZBM UEFI → 各架构 BOOT*.EFI（见 Boot.md）
        ├─ ZBM BIOS → build/tmp/mbr.bin, vbr.bin, stage2.bin（x86_64）
        └─ ISO → xorriso + FAT ESP（mkiso-uefi-zbm.sh；x86_64）
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
| 内核 ELF | `build/tmp/kernel.elf` | 内核映像（x86_64 含 Multiboot2 头） |
| ZBM UEFI | `build/tmp/` 或 ESP 镜像 | `BOOTX64.EFI` / `BOOTAA64.EFI` 等 |
| ZBM MBR | `build/tmp/mbr.bin` | ZBM 主引导记录 |
| ZBM VBR | `build/tmp/vbr.bin` | ZBM 卷引导记录 |
| ZBM Stage2 | `build/tmp/stage2.bin` | ZBM 第二阶段加载器 |
| ISO 镜像 | `build/release/zirconos-1.0.0-{arch}.iso` | 可启动 ISO |

## 8. 系统配置文件

默认配置位于 `src/config/`，编译时通过 `@embedFile` 嵌入内核：

| 文件 | 说明 |
|------|------|
| `src/config/system.conf` | 系统核心参数：主机名、内存、调度策略、显示、文件系统 |
| `src/config/boot.conf` | 引导配置：超时、Multiboot 参数、`[display]` gfxmode（与 RESOLUTION 同步）、UEFI/ZBM |
| `src/config/desktop.conf` | 桌面环境：主题选择、DWM 配置、任务栏、字体 |
| `src/config/defaults.zig` | `@embedFile` 加载上述 .conf |

`src/config/config.zig` 负责在运行时解析这些配置并提供访问接口。

## 9. 依赖安装

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y xorriso mtools dosfstools \
    qemu-system-x86 qemu-system-arm qemu-system-misc ovmf
```

可选（x86_64 ZBM BIOS：`as`/`ld`/`objcopy`，通常来自 `binutils`）。LoongArch / RISC-V 的 ZBM UEFI 见 Makefile 中 `fetch-gnu-efi`、`fetch-gnu-efi-riscv64` 与交叉工具链说明。

### Zig 编译器

从 [ziglang.org](https://ziglang.org/download/) 下载并加入 PATH。

## 10. 桌面主题与字体

主题源码与 `resources/` 位于 `src/desktop/aero/`。

开源字体需按需下载到 `src/fonts/`：

```bash
make fonts
# 或: ./scripts/fonts/fetch-fonts.sh
```

### Aero 声音与 Win32 图标资源 DLL（宿主机）

| 目标 / 场景 | 构建步骤 | 产物与说明 |
|-------------|----------|------------|
| x86_64（MinGW）真 PE | `zig build aero-shell-icons-dll` | `zig-out/assets/zircon_shell32_res.dll`（`RT_GROUP_ICON` / `RT_ICON`） |
| LoongArch64 占位（Tier 1） | `zig build aero-shell-icons-la-bundle` | `zig-out/assets/loongarch64/win/System32/*.ico` + `zircon_shell32_res.manifest.json`（`binary_form: ico_bundle`） |
| LoongArch `windows-gnu` COFF（Tier 2 探测） | `zig build aero-loongarch-windows-pe-probe` | 运行 `scripts/build/probe-loongarch-windows-gnu-shared.sh`；工具链未支持时 **失败属预期** |
| 将来真 LA PE DLL（预留） | `-Daero-la-pe-dll`（占位） | 上游就绪后再接构建逻辑；现阶段请用上一行 bundle |

- `zig build aero-sounds`：重生成 Aero 主题 WAV（需 **ffmpeg**、**python3**）。
- `zig build aero-shell-icons-dll`：自 SVG 生成 ICO，**`windres` + `zig cc -target x86_64-windows-gnu -shared`** 生成 **`zig-out/assets/zircon_shell32_res.dll`**（需 **inkscape** 或 **rsvg-convert**、**ImageMagick**、**MinGW windres**）。可加 `-Daero-skip-ico-build=true` 跳过 ICO 脚本。可与 Windows 7+ 上 `LoadLibrary` / `ExtractIconEx` 等 API 配合使用；说明见 [NT61_ShellIcons.md](NT61_ShellIcons.md)。
- `zig build aero-shell-icons-la-bundle`：将壳层 ICO 与 **`zircon_shell32_res.manifest.json`** 安装到 **`zig-out/assets/loongarch64/win/System32/`**（无 LoongArch PE DLL，供「Windows for LoongArch64」场景占位）；ICO 依赖与上一项相同。说明见 [NT61_ShellIcons.md](NT61_ShellIcons.md)。

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

**AArch64 / RISC-V64（QEMU `virt`，`Makefile` UEFI）**

- **AArch64**：早期日志走 PL011 **`0x09000000`**（`src/hal/aarch64/uart.zig`），`make run-aarch64` 的 `-serial stdio` 对应该 UART。
- **RISC-V64**：早期日志走 NS16550 MMIO **`0x10000000`**，失败时回退 SBI putchar（`src/hal/riscv64/uart.zig`）。无输出时可对照 `-nographic` 或 `-serial file:…`，并保持与 `make run-riscv64` 相同的 `-bios`、磁盘与 ramfb 参数。handoff 诊断见 `src/main.zig` 中 `HandoffDiag` / `BootHandoff` 与 [AeroDesktopRuntime.md §4.2.3](AeroDesktopRuntime.md)。
