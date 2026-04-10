# 构建与辅助脚本

## 目录结构

| 子目录 | 用途 |
|--------|------|
| `build/` | 内核/ISO/固件构建辅助 |
| `qemu/` | QEMU 虚拟机运行自动化 |
| `test/` | QEMU 烟测与分辨率矩阵 |
| `devtools/` | CI 检查、配置、文档工具 |
| `fetch/` | 资源下载（壁纸、字体、串口日志接入） |
| `debug/` | 串口调试与日志解析 |
| `fonts/` | 字体下载 |
| `tools/` | PE 相关工具（`fix_pe_reloc.py`、`PE_LOONGARCH_UEFI.md`） |
| `misc/` | 一次性/归档脚本（不推荐日常使用） |

---

## build/

构建辅助（14 个脚本）。

| 脚本 | 说明 |
|------|------|
| `mkiso-uefi-zbm.sh` | 生成 UEFI 可启动 ISO（`xorriso` + 内嵌 FAT ESP） |
| `fetch-gnu-efi.sh` | 克隆并编译 GNU-EFI（LoongArch64），输出到 `gnu-efi/loongarch64-built/` |
| `fetch-gnu-efi-riscv64.sh` | 同上，RISC-V64 |
| `fetch-gnu-efi-mips64el.sh` | 同上，MIPS64el |
| `fetch-firmware.sh` | 下载 QEMU 用 EDK2 nightly 固件到 `firmware/` |
| `zbm-loongarch64-efi.sh` | 将 `zbm_loongarch64.o` 链接为 `BOOTLOONGARCH64.EFI` |
| `zbm-riscv64-efi.sh` | 同上，RISC-V64 |
| `zbm-mips64el-efi.sh` | 同上，MIPS64el |
| `mkesp-loongarch64.sh` | 生成 LoongArch64 UEFI ESP 磁盘镜像 |
| `build-aero-icons.sh` | Aero SVG → 多尺寸 ICO（`src/desktop/aero/resources/win32/ico/`） |
| `build-zircon-icon-dll.sh` | ICO + RC → `zig-out/assets/zircon_shell32_res.dll`（MinGW）；或 `zig build aero-shell-icons-dll` |
| `probe-loongarch-windows-gnu-shared.sh` | 探测 `zig cc -target loongarch64-windows-gnu -shared` 是否可用；由 `zig build aero-loongarch-windows-pe-probe` 调用 |
| `build-stub-loongarch64.sh` | LoongArch64 stub 构建辅助 |
| `build-zbm-loongarch64-stub.sh` | LoongArch64 ZBM stub 构建辅助 |

> 内核运行时默认配置见 **`src/config/*.conf`**（由 `src/config/defaults.zig` 嵌入）。

---

## qemu/

QEMU 虚拟机运行自动化。

| 脚本 | 说明 |
|------|------|
| `loongarch-uefi-autorun.sh` | LoongArch64 QEMU 在固件 Shell 下自动输入启动路径（shell 脚本驱动） |
| `loongarch-uefi-autorun.py` | 同上，Python 版本 |

---

## test/

QEMU 烟测与多分辨率验证（10 个脚本）。

| 脚本 | 说明 |
|------|------|
| `ci-qemu-smoke.sh` | CI 烟测入口（`zig build test` + QEMU 冒烟） |
| `smoke-qemu-mbr.sh` | MBR 磁盘烟测 |
| `qemu_smp_smoke.sh` | SMP 多核烟测 |
| `test_loongarch_resolution_matrix.sh` | 多组 `WxHx32` 下 LoongArch64 编译冒烟；`--quick` 为三档代表分辨率（CI 使用） |
| `test_x86_resolution_matrix.sh` | 同上，x86_64 |
| `desktop-qa.sh` | 桌面 QA 验证 |
| `dwm_blur_resolution_matrix.sh` | DWM 模糊分辨率矩阵测试 |
| `loongarch_display_resolution_matrix.sh` | LoongArch 显示分辨率矩阵 |
| `qemu_desktop_perf_baseline.sh` | 桌面性能基线 |
| `qemu_loongarch64_smp_test.sh` | LoongArch64 SMP 测试 |

---

## devtools/

CI 检查、配置与文档工具（6 个脚本 + 1 个 Python）。

| 脚本 | 说明 |
|------|------|
| `check-docs-links.sh` | 校验 `docs/*.md` 与根目录 `README*.md` 中相对路径链接是否存在（CI 调用） |
| `check_amd_pci_ids.sh` | AMD GPU PCI ID 检查 |
| `contract_matrix_scan.sh` | 契约矩阵扫描 |
| `configure.py` | 交互式编辑根目录 `build.conf` |
| `sync_resolution_config.py` | 分辨率配置同步 |
| `verify-compliance.sh` | 合规检查：扫描源码内 `reactos`/`wine` 等可疑短语（**不能**替代人工审查） |

---

## fetch/

壁纸、字体等资源下载。

| 脚本 | 说明 |
|------|------|
| `fetch-assets.sh` | 缺失时生成 Aero 壁纸 PNG 占位（与 `build.zig` 中路径一致） |
| `gen_wallpaper_placeholders.py` | 同上，Python 独立版本 |
| `agent-ingest-serial.sh` | 串口日志接入辅助 |

字体：`scripts/fonts/fetch-fonts.sh` 下载开源字体到 `src/fonts/`。

---

## debug/

串口调试与日志解析。

| 脚本 | 说明 |
|------|------|
| `run_loongarch64_with_serial_debug_log.sh` | 串口同时进终端与 `serial_dbg_to_cursor_log.py`；等价 **`make run-loongarch64-serial-debug`** |
| `serial_dbg_to_cursor_log.py` | 从 stdin 解析 `DBG80cc1c` 行 → `.cursor/debug-80cc1c.log`（NDJSON）。勿单独 `make \| python`（终端会无输出） |

---

## tools/

PE 相关工具（不在构建主流程中，按需使用）。

| 文件 | 说明 |
|------|------|
| `fix_pe_reloc.py` | 修 LoongArch `.efi` Subsystem 字段 |
| `PE_LOONGARCH_UEFI.md` | LoongArch `.efi` 构建步骤、与社区 #108 重定位讨论的差异 |

---

## misc/

不推荐日常使用的一次性或归档脚本。

| 脚本 | 说明 |
|------|------|
| `restructure_gate.sh` | 重构门控脚本（维护工具） |
