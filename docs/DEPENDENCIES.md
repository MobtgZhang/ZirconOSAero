# ZirconOSAero 依赖版本锁定记录
#
# 本文件记录所有第三方依赖的版本信息，确保构建可重现性。
# 依赖版本变更时应更新此文件。
#
# 最后更新：2026-04-10

## Zig 工具链

| 依赖 | 要求版本 | 说明 |
|------|----------|------|
| **Zig** | ≥ 0.15.2（CI 锁定 0.15.2） | `minimum_zig_version` 见 `build.zig.zon`；主构建工具链，内核无 libc 依赖 |
| **Zig（交叉编译）** | ≥ 0.15.2 | 多架构（aarch64/riscv64/loongarch64）交叉编译支持 |

## 模拟器与运行环境

| 依赖 | 要求版本 | 说明 |
|------|----------|------|
| **QEMU** | ≥ 10.2（推荐最新） | 开发测试环境；支持 x86_64/aarch64/riscv64/loongarch64 |
| **QEMU 固件（LoongArch64）** | QEMU 10.2+ 内置 | LoongArch64 UEFI GOP / ramfb_cfg 支持；见 `scripts/qemu_loongarch64_smp_test.sh` |

## 构建辅助工具

| 依赖 | 版本 | 用途 | 更新方式 |
|------|------|------|--------|
| **gnu-efi** | 见 `gnu-efi` 子模块 或 `scripts/build/fetch-gnu-efi-mips64el.sh` | x86_64/loongarch64/riscv64 UEFI 应用链接 | `git submodule update --init` 或运行脚本 |
| **mtools** | 系统包管理器安装 | FAT12/16/32 镜像创建 | `apt install mtools` / `dnf install mtools` |
| **xorriso** | 系统包管理器安装 | ISO9660 镜像创建（UEFI 混合镜像） | `apt install xorriso` / `dnf install xorriso` |
| **xbuild / mingw-w64** | 系统包管理器安装 | Win32 资源编译（windres） | `apt install mingw-w64` |
| **windres**（MinGW） | mingw-w64 附带 | PE 资源（ICO/manifest）编译 | 同上 |

## 子模块 / 第三方源码

（无外部子模块依赖；所有图片解码器位于 `src/libs/image/` 目录）

## CI 锁定的版本策略

- **Zig 版本**：CI 固定为 0.15.2，本地开发可使用更新的 Zig（向后兼容），但 CI 以锁定版本为准
- **QEMU 版本**：CI 使用最新稳定版（≥ 10.2），本地建议与 CI 对齐；LoongArch64 需要 QEMU 10.2+ 以获得完整 GOP/ramfb_cfg 支持
- **依赖哈希**：所有第三方子模块使用具体 commit hash，禁止使用 `main` / `master` HEAD

## 验证构建可重现性

```bash
# 验证工具链版本
zig version    # 应输出 0.15.2 或 CI 锁定版本
qemu-system-x86_64 --version

# 运行完整构建
zig build install
zig build test
```
