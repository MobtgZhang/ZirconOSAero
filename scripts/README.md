# 构建与辅助脚本

| 路径 | 说明 |
|------|------|
| `check-docs-links.sh` | 校验 `docs/*.md` 与根目录 `README*.md` 中**相对路径**链接是否存在（CI 调用） |
| `fetch-assets.sh` / `gen_wallpaper_placeholders.py` | 缺失时生成 Aero 壁纸 PNG 占位（与 `build.zig` 中路径一致） |
| `configure.py` | 交互式编辑根目录 `build.conf` |
| `build/mkiso-uefi-zbm.sh` | 生成 UEFI 可启动 ISO（`xorriso` + 内嵌 FAT ESP） |
| `build/fetch-gnu-efi.sh` | 克隆并编译 GNU-EFI（LoongArch），输出到 `gnu-efi/loongarch64-built/` |
| `build/fetch-firmware.sh` | 下载 QEMU 用 EDK2 nightly 固件到 `firmware/` |
| `build/zbm-loongarch64-efi.sh` | 将 `zbm_loongarch64.o` 链接为 `BOOTLOONGARCH64.EFI` |
| `build/mkesp-loongarch64.sh` | 生成 LoongArch UEFI 用 ESP 磁盘镜像 |
| `fonts/fetch-fonts.sh` | 下载开源字体到 `src/fonts/` |
| `build/build-aero-icons.sh` | Aero SVG → 多尺寸 ICO（`src/desktop/aero/resources/win32/ico/`） |
| `build/build-zircon-icon-dll.sh` | ICO + RC → `zig-out/assets/zircon_shell32_res.dll`（MinGW）；或 `zig build aero-shell-icons-dll` |
| `build/probe-loongarch-windows-gnu-shared.sh` | 探测 `zig cc -target loongarch64-windows-gnu -shared` 是否可用；由 `zig build aero-loongarch-windows-pe-probe` 调用 |
| `qemu/loongarch-uefi-autorun.*` | LoongArch QEMU 在固件 Shell 下自动输入启动路径 |
| `test_loongarch_resolution_matrix.sh` | 多组 `WxHx32` 下 `zig build -Darch=loongarch64` + `zbm-loongarch-uefi` 编译冒烟；`--quick` 为三档代表分辨率（CI 使用） |
| `run_loongarch64_with_serial_debug_log.sh` | `tee >(python3 …)`：串口**同时**进终端与 `serial_dbg_to_cursor_log.py`；等价 **`make run-loongarch64-serial-debug`** |
| `serial_dbg_to_cursor_log.py` | 从 stdin 解析 `DBG80cc1c` 行 → `.cursor/debug-80cc1c.log`（NDJSON）；勿单独 `make \| python`（终端会无输出） |
| `tools/PE_LOONGARCH_UEFI.md` | LoongArch `.efi` 构建步骤、与社区 #108 重定位讨论的差异；`fix_pe_reloc.py` 仅修 Subsystem |

内核运行时默认配置见 **`src/config/*.conf`**（由 `src/config/defaults.zig` 嵌入）。
