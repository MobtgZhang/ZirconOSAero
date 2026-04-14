// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! USB HID Boot Protocol：解析引导键盘/鼠标报告；鼠标送入 `mouse.deliverMouseEvent`（问题六 M2），键盘经 `arch.injectSyntheticChar` 与 PS/2 队列汇合（`input_hub.pollAll` 顺序见该文件头注释）。

const mouse = @import("../input/mouse.zig");
const klog = @import("../../rtl/klog.zig");
const boot_rep = @import("hid_boot_report.zig");
const arch = @import("../../arch.zig");

/// Boot mouse 报告（常见 3–4 字节；见 `hid_boot_report.parseBootMouseReport`）。
/// 将 Boot Keyboard usage（子集）映射为可打印 ASCII 并注入；完整扫描表为长期项。
fn hidUsageToAscii(usage: u8) ?u8 {
    if (usage >= 0x04 and usage <= 0x1d) return 'a' + (usage - 0x04);
    if (usage == 0x28) return '\r';
    if (usage == 0x2c) return ' ';
    return null;
}

pub fn deliverBootKeyboardReport(buf: []const u8) void {
    const k = boot_rep.parseBootKeyboardReport(buf) orelse return;
    for (k.keys) |code| {
        if (code == 0) continue;
        if (hidUsageToAscii(code)) |ch| {
            if (@hasDecl(arch, "injectSyntheticChar")) {
                arch.injectSyntheticChar(ch);
            }
        }
    }
    if (klog.DEBUG_MODE and k.modifiers != 0) {
        klog.debug("USB HID boot kbd modifiers=0x%x", .{k.modifiers});
    }
}

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
