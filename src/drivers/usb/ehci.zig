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

//! EHCI（USB2）主机：占位。无 xHCI 时可扩展 QH/qTD 异步/周期列表。
//! QEMU `-device usb-ehci` 等场景；当前仅记录 PCI 发现结果。

const builtin = @import("builtin");
const pcie = @import("../bus/pcie.zig");
const klog = @import("../../rtl/klog.zig");
const build_options = @import("build_options");

pub fn tryInit(info: pcie.UsbHostPciInfo) bool {
    if (!build_options.usb_ehci) return false;
    if (builtin.target.cpu.arch == .x86_64) {
        klog.info("USB EHCI: stub (bus=%u dev=%u fn=%u) — use -usb_xhci or implement QH/qTD", .{
            info.loc.bus, info.loc.dev, info.loc.func,
        });
    }
    return false;
}
