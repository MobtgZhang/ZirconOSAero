# 问题 #46：BootVID 停用后残留启动日志

## 1. 问题编号

`46`

## 2. 问题位置

- 文件路径：`src/drivers/video/bootvid.zig`
- 函数/模块：`deactivate`

## 3. 问题描述

进入桌面前调用 BootVID 停用时，只切换了日志开关，没有清空 BootVID 阶段写入的帧缓冲，可能在桌面初始化瞬间留下旧启动日志残影。

## 4. 复现路径

在 x86_64 QEMU 中进入 UEFI → BootVID → DWM 桌面链路，观察 BootVID 日志向桌面首帧过渡的边界。

## 5. 影响范围

- 桌面首帧可能出现旧内核日志；
- 与“桌面阶段屏幕静默、串口保留全量日志”的目标不一致。

## 6. 严重程度

- Medium

## 7. 可能原因

`deactivate()` 没有对 BootVID 使用的帧缓冲执行清屏操作。

## 8. 权威参考依据

- 项目三阶段显示链路要求：UEFI GOP → BootVID → 桌面正式 GPU；
- `reports/041-desktop-serial-screen-log-split.md` 已定义屏幕与串口的日志边界；
- 本条未使用 REA 对照 Windows 7 镜像，因为这是本项目启动阶段边界的显示残影问题。

## 9. 建议修复方案

在 `deactivate()` 中先停用 BootVID 日志，再清空帧缓冲。随后 DWM 渲染首帧，避免残留内容。

## 10. 验证方法

1. 使用 Zig 0.18.0-dev 构建并生成 ESP；
2. 用 QEMU x86_64 + VirtIO GPU 启动；
3. 检查串口仍有完整日志；
4. 确认桌面渲染路径不再叠加 BootVID 日志残影。

## 11. 状态

- Fixed
