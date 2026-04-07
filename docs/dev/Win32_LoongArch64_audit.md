# Win32 子系统 — LoongArch64 分支审计摘要

审计日期：以仓库当前 `builtin.cpu.arch == .loongarch64` 为准。

| 区域 | 文件 | 说明 |
| --- | --- | --- |
| 显示 / IOCTL | `src/drivers/video/core/display.zig` | `IOCTL_DISPLAY_SET_MODE`：`fb_address` 非零可走 `ramfb.runtimeReconfigureAtGuestPhys` |
| 帧缓冲栅栏 | `src/drivers/video/core/framebuffer.zig` | `dbar 0` store fence |
| 桌面会话 | `src/kernel/desktop_session.zig` | ramfb 扫描、输入轮询次数 |
| 其它 user32/gdi/dwm | 多数与架构无关；若新增 LA 分支须补主机布局测试 | |

回归：`tests/nt61/display_set_mode_ioctl_layout_host.zig`，`zig build test`。
