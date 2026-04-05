//! 输入总线聚合：VirtIO-Input PCI 与 PS/2 8042（及 USB HID）**统一经本入口**，再进入 `mouse.zig` 的合并/插值队列（问题六：禁止并行第二套指针状态机）。
//! **单轮顺序（M3）**：`usb.poll`（`-Dusb_xhci` 且 xHCI 活跃）→ `virtio_input_pci.poll` →（x86_64 且 VirtIO 未 attach）`mouse.poll` PS/2。与 [PointerPolicy_NT61.md](../../docs/cn/PointerPolicy_NT61.md) §4 双源策略一致。
//! **阶段 D-D1-8**：桌面主循环在 `mouse.popEvent` / `display.handleMouseMove` **之前**先 `pollAll` 排空设备；消息投递（若有 Win32 用户线程）须在输入取样之后，避免「读队列先于硬件刷新」的竞态；详见 `main.zig` `runDesktopMainLoop`。
const builtin = @import("builtin");

/// LoongArch 定时器/硬件中断里也会调用 `pollAll`（见 `ke/interrupt_loongarch.zig`），与桌面主循环并发重入。
/// 内层若再次 `beginMotionCoalesce` 会清空外层已累积的合并位移，易触发异常路径；仅最外层包一对 begin/end。
var poll_depth: u32 = 0;

pub fn pollAll() void {
    const mouse = @import("mouse.zig");
    poll_depth += 1;
    defer poll_depth -= 1;
    const outer = poll_depth == 1;
    if (outer) {
        mouse.beginMotionCoalesce();
    }
    defer {
        if (outer) mouse.endMotionCoalesce();
    }

    if (@import("../usb/usb.zig").xhciIsActive()) {
        @import("../usb/usb.zig").poll();
    }

    const virtio_input_pci = @import("virtio_input_pci.zig");
    virtio_input_pci.poll();
    if (builtin.target.cpu.arch == .x86_64) {
        // QEMU 默认同时挂 virtio-mouse/tablet 与 i8042；VirtIO 已 attach 时再以 PS/2 排空会导致双倍相对位移。
        if (!virtio_input_pci.isActive()) {
            mouse.poll();
        }
    }

    @import("mouse_debug.zig").noteInputHubRound();
}
