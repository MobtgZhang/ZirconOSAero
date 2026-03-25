//! USB HID Boot Protocol：解析引导鼠标报告并送入 `mouse.deliverMouseEvent`。

const mouse = @import("../input/mouse.zig");
const klog = @import("../../rtl/klog.zig");

/// Boot mouse 报告（8 字节常见；至少前 3 字节：buttons, dx, dy）
pub fn deliverBootMouseReport(buf: []const u8) void {
    if (buf.len < 3) return;
    const buttons = buf[0];
    const dx: i8 = @bitCast(buf[1]);
    const dy: i8 = @bitCast(buf[2]);
    var scroll: i8 = 0;
    if (buf.len >= 4) scroll = @bitCast(buf[3]);
    mouse.deliverMouseEvent(.{
        .dx = dx,
        .dy = -dy,
        .buttons = buttons,
        .scroll = scroll,
    });
    if (klog.DEBUG_MODE and (buttons != 0 or dx != 0 or dy != 0)) {
        klog.debug("USB HID boot mouse: btn=%u dx=%d dy=%d", .{ buttons, dx, dy });
    }
}
