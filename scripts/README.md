# 构建与辅助脚本

| 路径 | 说明 |
|------|------|
| `configure.py` | 交互式编辑根目录 `build.conf` |
| `build/mkiso-uefi-zbm.sh` | 生成无 GRUB 的 UEFI 可启动 ISO（`xorriso` + 内嵌 FAT ESP） |
| `build/fetch-gnu-efi.sh` | 克隆并编译 GNU-EFI（LoongArch），输出到 `gnu-efi/loongarch64-built/` |
| `build/fetch-firmware.sh` | 下载 QEMU 用 EDK2 nightly 固件到 `firmware/` |
| `build/zbm-loongarch64-efi.sh` | 将 `zbm_loongarch64.o` 链接为 `BOOTLOONGARCH64.EFI` |
| `build/mkesp-loongarch64.sh` | 生成 LoongArch UEFI 用 ESP 磁盘镜像 |
| `fonts/fetch-fonts.sh` | 下载开源字体到 `src/fonts/` |
| `qemu/loongarch-uefi-autorun.*` | LoongArch QEMU 在固件 Shell 下自动输入启动路径 |

内核运行时默认配置见 **`src/config/*.conf`**（由 `src/config/defaults.zig` 嵌入）。
