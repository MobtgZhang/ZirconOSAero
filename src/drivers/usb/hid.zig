//! USB HID Boot Protocol：解析引导鼠标报告并送入 `mouse.deliverMouseEvent`（问题六 M2）。

const mouse = @import("../input/mouse.zig");
const klog = @import("../../rtl/klog.zig");
const boot_rep = @import("hid_boot_report.zig");

/// Boot mouse 报告（常见 3–4 字节；见 `hid_boot_report.parseBootMouseReport`）。
pub fn deliverBootMouseReport(buf: []const u8) void {
    const p = boot_rep.parseBootMouseReport(buf) orelse return;
    mouse.deliverMouseEvent(.{
        .dx = p.dx,
        .dy = -p.dy,
        .buttons = p.buttons,
        .scroll = p.scroll,
    });
    if (klog.DEBUG_MODE and (p.buttons != 0 or p.dx != 0 or p.dy != 0)) {
        klog.debug("USB HID boot mouse: btn=%u dx=%d dy=%d", .{ p.buttons, p.dx, p.dy });
    }
}
