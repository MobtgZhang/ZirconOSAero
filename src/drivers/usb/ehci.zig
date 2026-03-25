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
