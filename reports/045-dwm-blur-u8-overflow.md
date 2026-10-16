# 问题 #45：DWM 模糊半径回退为 u8 导致整数溢出

## 1. 问题编号

`45`

## 2. 问题位置

- 文件路径：`src/drivers/video/core/dwm.zig`
- 函数/模块：`renderGlassEffectInternal`
- 行号或代码片段：`const tr = @min(blur_r, @as(u32, 6));`，后续执行 `tr * 2 / 3`

## 3. 问题描述

虽然 `blur_r` 已由 `u8` 转换为 `u32`，但编译器在 `@min` 与常量结合后可能将中间结果推断回更窄的整数类型，导致 `tr * 2` 生成 `u8` 溢出检查。任务栏模糊半径为 `4`、`5`、`6` 时，`tr * 2` 本应不溢出，却在运行时触发 `integer overflow`。

## 4. 复现路径

在 x86_64 QEMU 中挂载含 Aero 桌面的 ESP，进入桌面并触发任务栏/标题栏玻璃模糊路径。修复前 panic 返回地址为 `0x226f09f`，addr2line 定位到 `renderGlassEffectInternal`。

## 5. 影响范围

- 桌面合成线程在首次呈现前崩溃；
- 用户无法进入 Aero 桌面；
- 任务栏与标题栏模糊、高光和 chrome 边框都无法完成。

## 6. 严重程度

- Critical

## 7. 可能原因

Zig 0.18-dev 对 `@min`、`@max` 与 `@as` 组合的结果类型收窄不符合直觉；`u8` 配置字段进入半径表达式后，编译器生成了窄类型乘法。

## 8. 权威参考依据

- Windows 7 / NT 6.1 DWM 会在合成器阶段执行玻璃效果；本项目依据 `docs/cn/AeroRendering.md` 与 `src/config/nt61_aero_defaults.zig` 的行为契约。
- QEMU x86_64 实机 panic 日志与 `addr2line -e build/tmp/winload.efi -f -C 0x226f09f`。
- 本次未使用 Windows 7 镜像做逆向对照，因为该缺陷是源代码类型推断问题，而非 Windows 行为差异。

## 9. 建议修复方案

将模糊半径、遍数、上限、递减半径等全部显式声明为 `u32`。乘法保持在小上限范围内的窄整数运算不再影响结果类型。

## 10. 验证方法

1. 使用 Zig 0.18.0-dev 执行 `make build ARCH=x86_64`；
2. 执行 `make build-esp ARCH=x86_64`；
3. 用 QEMU x86_64 + VirtIO GPU 启动 ESP；
4. 等待桌面首帧呈现、`dwm.exe` 与 `cmd.exe` 启动；
5. 确认日志中不再出现 `integer overflow`，且 `Desktop: first frame presented` 存在。

## 11. 状态

- Fixed
