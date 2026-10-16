# 问题 #51：QEMU GTK 宿主鼠标事件不转发到 VirtIO 输入设备

## 1. 问题编号

`51`

## 2. 问题位置

- 文件路径：`Makefile`（QEMU 启动参数）、`scripts/devtools/qemu_select_virtio_pointer.py`（指针选择）、`src/drivers/input/virtio_input_pci.zig`（内核 VirtIO 输入驱动）
- 函数/模块：QEMU display gtk + virtio-input-pci 输入路由
- 行号或代码片段：`Makefile:195-197`（UEFI 输入设备）、`scripts/devtools/qemu_select_virtio_pointer.py`（mouse_set 选择）

## 3. 问题描述

QEMU 10.2.1 GTK 显示后端的宿主鼠标事件无法可靠到达 VirtIO 输入设备；实际验证中，只有 VNC 显示后端 + VirtIO Mouse 这条链路能将宿主实时指针事件送入内核。内核侧 VirtIO 输入驱动本身初始化、轮询、移动事件分发正常。

## 4. 复现路径

1. `make run ARCH=x86_64 BOOT_METHOD=uefi`（QEMU GTK 显示 + `virtio-tablet-pci,display=zircon_vgpu` + `i8042=off`）
2. 启动脚本自动执行 `mouse_set` 选择 Virtio Tablet（`query-mice` 确认 `current=true, absolute=true`）
3. 在 QEMU GTK 窗口内移动宿主鼠标
4. 观察：内核 `MOUSEDBG virtio inst=N used.idx=0` 不变，光标不移动
5. 对照：通过 QMP `input-send-event` 注入绝对/相对事件，`used.idx` 立即前进且光标移动

## 5. 影响范围

- 影响模块：QEMU GTK 显示后端 + VirtIO 输入设备 + 桌面指针
- 用户行为：宿主鼠标在 QEMU 窗口内移动无效
- 系统行为：内核指针状态机无输入事件，光标停留在初始位置
- 兼容性：QMP 注入正常（测试可行），仅宿主实时鼠标失效
- 安全性/稳定性：无安全风险；不影响内核稳定性

## 6. 严重程度

- High

## 7. 可能原因

QEMU GTK 显示后端使用**旧版** `qemu_add_mouse_event_handler` 输入 API，而 VirtIO 输入设备注册使用**新版** `qemu_input_handler_register` API。两套 API 在 QEMU 10.x 中未打通：

- `mouse_set` 切换的是旧版 current mouse，但 GTK 的事件派发不经过新版 handler 列表
- `input-send-event` QMP 命令直接通过新版 API 派发，因此可正确到达 VirtIO 设备
- HMP `mouse_move` 通过旧版 API 派发，同样无法到达 VirtIO 设备

## 8. 权威参考依据

- QEMU 10.2.1 `query-mice`：确认 Virtio Tablet `current=true, absolute=true`
- 内核串口 `MOUSEDBG`：`used.idx=0`（无宿主事件）→ QMP 注入后 `used.idx=3`（事件到达且光标移动）
- QEMU HMP `mouse_move` / `mouse_set`：命令执行成功但事件未到达 VirtIO virtqueue
- QEMU `-device virtio-tablet-pci,display=…`：`display` 绑定仅影响 QMP `input-send-event` 路由，不影响 GTK 宿主事件
- QEMU 10.2.1 无 `-M q35,no-ps2-mouse=on` 单独禁用 PS/2 鼠标的选项；`i8042=off` 同时禁用键盘控制器（内核已适配）

## 9. 建议修复方案

**QEMU 层（外部限制，无法通过本项目代码修复）：**
- 使用 VNC（`-display none -vnc :0`）或 SPICE 替代 GTK 显示后端，它们使用新版输入 API，宿主事件可正确路由到 VirtIO 设备
- 或等待 QEMU 上游修复 GTK + VirtIO input 的事件路由

**内核层（已确认正确，无需修改）：**
- `virtio_input_pci.zig` 的初始化、轮询、绝对/相对事件分发均正常
- `mouse.zig` 的 `deliverAbsoluteMotionEvent` / `deliverMouseEventUncoalesced` 均可正确处理事件

**测试验证（可行）：**
- 通过 QMP `input-send-event` 注入绝对/相对事件验证内核指针移动
- 通过 `scripts/devtools/qemu_select_virtio_pointer.py` 确认 Virtio Tablet 为 current

## 10. 验证方法

1. 启动 QEMU（GTK + virtio-tablet + i8042=off）
2. 等待内核进入桌面（`MOUSEDBG desktop tick=N` 出现）
3. 记录 `MOUSEDBG virtio inst=N used.idx=M`
4. 在 GTK 窗口内移动宿主鼠标 → `used.idx` 不变（复现）
5. 通过 QMP 注入 `input-send-event` → `used.idx` 前进且光标移动（证明内核正确）
6. 若需宿主实时鼠标，改用 VNC：`-display none -vnc :0` + VNC 客户端

## 11. 状态

- Fixed

## 12. 复核结论

根因不是内核 VirtIO 驱动，而是两层组合问题：

1. QEMU GTK 宿主指针默认路由到 legacy `QEMU PS/2 Mouse`；
2. 实际复核发现：宿主事件经 VNC 路由到 VirtIO Mouse 才是可靠路径；GTK 的 xtest 事件既未到达 VirtIO，也未稳定到达 PS/2。

修复后的策略是：默认使用 QEMU VNC 显示后端，并通过 `mouse_set` 优先选择 VirtIO Tablet/Mouse；PS/2 只作为无 VirtIO 设备时的兼容回退。内核在 PC 平台同时排空 PS/2 与 VirtIO。

**实际验证证据（VNC + VirtIO Mouse）：**

- QEMU 选择：`qemu-pointer: selected QEMU Virtio Mouse (index 3, absolute=False)`。
- 真实 VNC 宿主事件后，`MOUSEDBG virtio inst=0 active=1 used.idx=23 last_used=23`。
- 桌面坐标变化：`MOUSEDBG desktop tick=1 pos=(881,337)` → `tick=2 pos=(1000,250)` → 后续 `pos=(1399,899)`。
- 结论：宿主指针已实际进入内核并驱动桌面坐标，不再停留在中心。

GTK 后端因 QEMU 事件路由限制，不能作为当前验证主链路。
