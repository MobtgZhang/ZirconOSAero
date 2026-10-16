# 问题 #2：ISO 目标的架构镜像选择与真实构建验证仍不完整

## 1. 问题编号

`2`

## 2. 问题位置

- 文件路径：`Makefile:427-445`、`scripts/build/mkiso-uefi-zbm.sh`
- 函数/模块：`iso`、`iso-debug`、`iso-release` 目标；UEFI ISO 封装脚本
- 相关测试：`tests/test_boot_combinations.py`

## 3. 问题描述

项目此前声明了 `iso`、`iso-debug`、`iso-release` 目标，却没有对应 recipe，导致 ISO 目标无法执行。本轮已补齐目标和封装脚本：脚本检查 ESP 输入、检查 `xorriso`、从 ESP helper 生成的 GPT 整盘镜像中提取 LBA 2048 起始的 FAT 分区，并使用 UEFI no-emulation El Torito 参数生成 ISO。

但当前目标在调用脚本时统一传入 `$(ESP_IMG)`。Makefile 同时为 `aarch64`、`riscv64`、`loongarch64` 定义了独立的 ESP 镜像变量，尚未证明所有架构的 `build-esp` 都会把结果写入 `$(ESP_IMG)`；因此多架构 ISO 产物选择仍需真实构建或进一步代码对照验证。

**2026-10-15 更新**：当前环境已安装 `mtools` 和 `zig 0.18.0`，ESP 镜像构建（`build-esp`）和 QEMU UEFI 启动验证通过。`xorriso` 仍未安装，ISO 目标（`make iso`）仍不可用，但 ESP 镜像作为主要启动产物已完成验证。

## 4. 复现路径

1. 在项目根目录执行 `make -n iso ARCH=aarch64 BOOT_METHOD=uefi BOOTLOADER=zbm`，观察目标会把 `$(ESP_IMG)` 传给 ISO 脚本。
2. 在缺少 `xorriso` 的环境执行 `make iso`，脚本明确失败并提示安装依赖。
3. 在具备依赖但未生成对应 ESP 的环境执行 `make iso`，脚本会报告输入镜像不存在。

## 5. 影响范围

- x86-64 ISO 路径已有脚本级和 fake-`xorriso` 测试覆盖，但真实产物尚未验证。
- 其他架构可能封装错误的 ESP 镜像，导致启动介质内容与目标架构不匹配。
- 构建失败属于显式失败，不会静默伪造 ISO；但 CI 若只执行 dry-run，无法发现真实工具链或镜像选择问题。

## 6. 严重程度

- High（多架构发布路径）

## 7. 可能原因

ISO 目标复用了通用 `ESP_IMG` 变量，而架构专用变量的实际产出约定未统一；同时本机缺少完整 UEFI ISO 工具链，无法完成端到端验证。

## 8. 权威参考依据

- 项目源码：`Makefile` 中同时声明 `ESP_IMG`、`ESP_IMG_AARCH64`、`ESP_IMG_RISCV64`、`ESP_IMG_LOONGARCH64`。
- 项目源码：`scripts/build/mkiso-uefi-zbm.sh` 使用 `xorriso -as mkisofs -e efiboot.img -no-emul-boot`；该参数组合属于 UEFI El Torito 封装路径，不等同于已完成固件启动验证。
- 实际验证：`python3 tests/test_boot_combinations.py` 的 33 项测试通过；测试使用 fake `xorriso`，不能证明真实 ISO 能被 QEMU/固件启动。
- 依赖检查：当前环境未安装 `xorriso`、`mtools`、`zig`，故真实构建状态为未知。
- REA/Windows 7 镜像对照：本问题是项目 ISO 构建链问题，不依赖 Windows 7 PE 行为；不得虚构 REA 证据。
- `/home/mobtgzhang/api.json` 仅为 API 接入配置，不含 Windows API 行为描述，不能作为本问题依据。

## 9. 建议修复方案

- 明确每个架构 `build-esp` 的输出变量，并在 ISO 目标中按 `ARCH` 选择对应 ESP 镜像。
- 增加真实工具链下的 ISO 构建和 QEMU/UEFI 启动验证；保留缺依赖时的显式失败。
- 在确认架构输出约定前不宣称 ISO 已完成或已通过 Windows 7 行为对照。

## 10. 验证方法

- 在具备 `zig`、`mtools`、`dosfstools`、`xorriso` 和对应 UEFI 固件的环境分别执行各架构 `make iso-debug`。
- 检查 ISO 内 El Torito EFI 镜像的 SHA-256、FAT 分区内容和架构启动文件名。
- 使用 QEMU/OVMF 启动每个 ISO，并记录固件、启动加载器和内核日志。
- 对本项目关键 PE/驱动兼容实现，另行使用 REA 与 Windows 7 镜像进行静态对照；本报告不将 ISO 测试冒充二进制行为证据。

## 11. 状态

- Need Verification（ESP 镜像已验证；ISO 目标待 `xorriso` 安装后验证）

## 12. 修复说明

已补充 `iso`、`iso-debug`、`iso-release` 目标和 `mkiso-uefi-zbm.sh`，并加入依赖缺失、输入镜像缺失及 fake-`xorriso` 测试。多架构变量选择和真实固件启动仍待验证。
