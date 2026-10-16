# 问题 #50：QEMU GUI 指针默认路由到 PS/2 而不是 VirtIO Tablet

## 1. 问题编号

`50`

## 2. 问题位置

- 文件路径：`Makefile`
- 函数/模块：QEMU x86-64 UEFI 运行配置
- 文件路径：`scripts/devtools/qemu_select_virtio_pointer.py`
- 函数/模块：QEMU 当前指针选择助手

## 3. 问题描述

QEMU GTK/SDL 显示后端会把主机物理指针事件发送给 QEMU 当前鼠标设备。即使已经挂载 `virtio-mouse-pci` 和 `virtio-tablet-pci`，QEMU 默认当前指针仍是 legacy `QEMU PS/2 Mouse`。因此内核虽然正确注册了 VirtIO 输入设备，GUI 物理指针仍不会进入 VirtIO Tablet 路径，表现为桌面鼠标停在中心。

## 4. 复现路径

1. 启动 x86-64 UEFI QEMU，挂载 VirtIO GPU、VirtIO 鼠标、VirtIO 键盘和 VirtIO Tablet。
2. 使用 QMP `query-mice` 查看设备。
3. 观察默认 `current: true` 项为 `QEMU PS/2 Mouse`，而不是 `QEMU Virtio Tablet`。
4. 使用 GUI 主机指针移动鼠标，内核桌面坐标不变。

## 5. 影响范围

- GTK/SDL 主机物理指针无法驱动桌面光标移动。
- QMP 注入相对事件可能看似可用，但不能证明真实 GUI 指针路径已修复。
- VirtIO Tablet 的绝对定位能力被绕过，桌面输入体验不稳定。

## 6. 严重程度

- High

## 7. 可能原因

QEMU 的默认指针选择不等于第一个挂载的指针设备；legacy PS/2 鼠标会继续作为默认当前指针。仅移除 `-vga std` 并挂载 VirtIO 输入设备不足以改变当前指针。

## 8. 权威参考依据

- QEMU `query-mice` 实际返回结果：`QEMU PS/2 Mouse` 初始为 `current: true`，`QEMU Virtio Tablet` 为 `current: false, absolute: true`。
- QEMU HMP `mouse_set` 实际执行后，`query-mice` 确认 `QEMU Virtio Tablet` 变为 `current: true`。
- Windows 桌面输入路径行为参考 `reports/049-desktop-icon-rendering-and-input-fix.md`；本问题不涉及 Windows 7 二进制对照，因为根因位于 QEMU 主机指针到虚拟设备的路由层。

## 9. 建议修复方案

- x86-64 UEFI 运行路径保留 VirtIO GPU 和 VirtIO 输入设备，同时移除 `-vga std`。
- 启动 QEMU 后通过 QMP 执行 `query-mice`，选择绝对定位的 `QEMU Virtio Tablet`。
- 用 HMP `mouse_set` 将其设为当前指针；无绝对设备时回退到 VirtIO 相对鼠标。
- QMP socket 使用随机路径，避免上次残留 socket 导致重复启动失败。

## 10. 验证方法

1. 运行 `make run ARCH=x86_64 BOOT_METHOD=uefi`。
2. 启动日志应出现 `qemu-pointer: selected QEMU Virtio Tablet (...)`。
3. 运行时 QMP `query-mice` 应显示 `QEMU Virtio Tablet` 为 `current: true, absolute: true`。
4. 移动 GUI 主机指针，串口 `MOUSEDBG desktop tick=... pos=(...)` 的坐标应随指针变化。
5. 运行 `make build ARCH=x86_64` 确认无回归。

## 11. 状态

- Fixed
