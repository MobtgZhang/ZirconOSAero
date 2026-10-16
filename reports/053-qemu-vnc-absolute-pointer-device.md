# 问题 #53：QEMU VNC 指针使用相对鼠标导致坐标不可控

## 1. 问题编号

`53`

## 2. 问题位置

- 文件路径：`Makefile`、`src/drivers/input/virtio_input_pci.zig`
- 函数/模块：`QEMU_X86_UEFI_INPUT`
- 行号或代码片段：UEFI 启动只挂载 `virtio-mouse-pci`，未提供绝对定位的 tablet 设备。

## 3. 问题描述

`make run` 默认使用 VNC 显示。VNC 的宿主移动事件经 QEMU 路由到 VirtIO 输入设备后，`virtio-mouse-pci` 以相对增量报告，受宿主指针加速和累计坐标影响，桌面指针经常停在不可预期位置；部分移动会被边界吸收，看起来像“鼠标不能移动”。
后续复测又发现一个独立根因：UEFI 配置同时存在 `zircon_vga` 与 `zircon_vgpu`，而 VNC 绑定的是 `zircon_vga`，tablet 却绑定到 `zircon_vgpu`，导致 VNC 指针事件不会到达 tablet。

## 4. 复现路径

1. 使用 `make run ARCH=x86_64 BOOT_METHOD=uefi` 启动到 Aero 桌面。
2. 连接 VNC 并向 `(200,200)`、`(720,300)`、`(1100,600)` 发送移动事件。
3. 旧配置中 QMP `query-mice` 显示 `QEMU Virtio Mouse` 的 `absolute=false`，指针位置与请求坐标不一致。

## 5. 影响范围

影响 QEMU/VNC 调试路径的桌面指针、图标点击、窗口焦点和 CMD 交互验证；不表示真机 PS/2 或 USB 指针必然失效。

## 6. 严重程度

- High

## 7. 可能原因

QEMU 会把 VNC 宿主指针事件转换为当前活动输入设备的协议。相对鼠标设备只保留增量，而 VNC 宿主坐标是绝对值；两者之间经 QEMU 指针加速换算后不稳定。

## 8. 权威参考依据

依据 QEMU 10.2.1 的 `query-mice` 实测结果：`QEMU Virtio Mouse` 为 `absolute=false`，`QEMU Virtio Tablet` 为 `absolute=true`。本条为运行时设备行为验证，未涉及 Windows 7 二进制对照。

## 9. 建议修复方案

在 x86_64 QEMU 输入设备中移除相对 `virtio-mouse-pci`，只保留绝对定位的 `virtio-tablet-pci` 与 `virtio-keyboard-pci`；同时移除 QEMU 10.2 中会触发崩溃的 `mouse_set` 启动辅助流程，让 VNC 直接路由到默认绝对 tablet。
UEFI 路径中 `virtio-tablet-pci` 的 `display` 必须与 VNC 实际显示的 `zircon_vga` 对齐；同时 VirtIO-GPU 不得在未上传 cursor resource 时发送 `MOVE_CURSOR`，避免隐藏软件光标。
另外，QEMU UEFI 机型必须设置 `i8042=off`。否则 legacy PS/2 鼠标仍可能抢占默认指针路由，导致 VNC/GUI 主机指针不进入 VirtIO Tablet。

## 10. 验证方法

1. 使用 Zig 0.18 构建 x86_64 UEFI ESP。
2. 使用 `q35,i8042=off` 与 tablet-only QEMU 配置，`QMP query-mice` 实测 `QEMU Virtio Tablet` 为 `absolute=true` 且 `current=true`（本机 QEMU 10.2.1 已复测通过）。
3. 通过 `vncdotool` 在同一个持久 VNC 连接中连续发送多个绝对坐标。
4. 串口 `desktop tick` 记录实际到达过 `(1020,650)`、`(1239,799)`、`(1420,899)`、`(1439,599)` 等多个不同位置，证明确认为持续移动而非单步伪装。
5. 队列 `used.idx` 在本次 QEMU 版本上不一定实时反映事件计数，因此以桌面坐标变化作为主要验证依据。
6. QMP `info vnc` 显示 `Display: zircon_vga`；`pgrep` 显示 `virtio-tablet-pci` 也绑定到 `zircon_vga`。`vncdotool` 连续移动到 `(1100,600)`、`(600,300)`、`(1200,700)` 后截图均可见指针移动。

## 11. 状态

- Fixed
