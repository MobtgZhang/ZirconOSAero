# 问题 #49：桌面图标渲染与鼠标输入修复

## 1. 问题编号

`49`

## 2. 问题位置

- 文件路径：`src/drivers/video/core/display.zig`
- 函数/模块：`renderOneIcon`
- 文件路径：`src/drivers/input/virtio_input_pci.zig`
- 函数/模块：`pollOne`、`syncDeliver`
- 文件路径：`src/drivers/input/mouse.zig`
- 函数/模块：`deliverMouseEventUncoalesced`

## 3. 问题描述

桌面图标在早期版本中呈现为白板。调试内核启用 `MOUSE_DEBUG` 后，VirtIO 输入 IRQ 热路径会调用 `mouseDbg`，导致 `klog` ticket 锁在关中断/中断路径上形成死锁，内核停在 AC97 初始化日志之后。

## 4. 复现路径

1. 使用 `make build-esp ARCH=x86_64 DEBUG_LOG=true` 构建 Debug 内核。
2. 启动 QEMU 并等待桌面初始化。
3. 通过 QMP 注入 `rel` 鼠标事件。

## 5. 影响范围

- 桌面图标显示异常。
- 调试构建进入桌面后被日志锁死锁。
- VirtIO 鼠标事件无法被安全验证。

## 6. 严重程度

High

## 7. 可能原因

1. 图标渲染路径直接绘制不透明矩形，缺少 Aero 风格半透明合成。
2. `mouseDbg` 在 VirtIO 输入 IRQ 热路径中调用，而 `klog` ticket 锁不适合在关中断/中断上下文递归或跨核等待。
3. QMP 注入时 `device` 参数应为显示设备（如 `zircon_vgpu`），而不是输入设备 ID（如 `zircon_mouse`）；错误传参会让 QEMU 试图在默认 console 上查找 `device` 属性。

## 8. 权威参考依据

- Windows 7 桌面视觉行为：任务栏与桌面图标使用玻璃/半透明选中态，而非不透明白色块。
- ReactOS 桌面图标渲染：图标标签与图标本体分离，悬停/选中状态使用主题化背景。
- QEMU QMP 文档：`input-send-event` 的 `device` 参数表示 display device/console，不等于输入控制器 ID。

## 9. 建议修复方案

- 将图标标签、选中态和悬停态改为半透明合成，并加入阴影/玻璃高光。
- 从 VirtIO 输入 IRQ 热路径移除 `mouseDbg` 调用，仅保留桌面主循环心跳日志。
- QMP 验证时使用 `device: "zircon_vgpu"` 发送输入事件。

## 10. 验证方法

1. `zig fmt --check`。
2. `make build-esp ARCH=x86_64 DEBUG_LOG=true -j2`。
3. 启动 QEMU 后使用 QMP 截屏，注入 `rel` 鼠标事件，再次截屏并做像素对比。
4. 验证桌面主循环持续输出 `MOUSEDBG desktop tick=...`，且不再停在 AC97 日志。

## 11. 状态

Fixed
