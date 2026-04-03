// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/net/virtio_net_pci.zig
// Purpose: VirtIO 网络 PCI（1af4:1000）枚举与 MMIO BAR 日志；与 `minimal_stack.zig`（ARP/IPv4/ICMP/UDP 解析子集）构成 H4 接线锚点。
//
// This is an independent clean-room implementation.
// Ref: Virtual I/O Device (VIRTIO) Version 1.2 — Network Device; PCI IDs 公开登记。
// Milestone: docs/cn/HAL_USB_NET_ROADMAP.md — QEMU virtio-net 默认机型。

const pcie = @import("../bus/pcie.zig");
const pci_bind = @import("../bus/pci_driver_bind.zig");
const klog = @import("../../rtl/klog.zig");
const minimal_stack = @import("minimal_stack.zig");

pub const pci_vendor_virtio: u16 = 0x1AF4;
pub const pci_device_virtio_net: u16 = 0x1000;

pub const VirtioNetPciDev = struct {
    loc: pcie.PciLoc,
    mmio: pcie.PciBarResource,
};

fn firstMmioBar(bars: [6]pcie.PciBarResource) ?pcie.PciBarResource {
    for (bars) |bar| {
        if (!bar.is_io and bar.base != 0 and bar.size > 0) return bar;
    }
    return null;
}

pub fn collectVirtioNetPci(out: []VirtioNetPciDev, max_bus: u8) usize {
    if (!pcie.supports_pci_config) return 0;
    var n: usize = 0;
    var b: u8 = 0;
    while (b <= max_bus) : (b += 1) {
        var d: u8 = 0;
        while (d < 32) : (d += 1) {
            var f: u8 = 0;
            while (f < 8) : (f += 1) {
                const id = pcie.readConfigDword(b, d, f, 0);
                if (id == 0xFFFFFFFF) continue;
                const vid: u16 = @truncate(id);
                const did: u16 = @truncate(id >> 16);
                const cls = pcie.readConfigDword(b, d, f, 0x08);
                if (pci_bind.lookupFromConfigClassWord(vid, did, cls) != .virtio_net) continue;
                pcie.enablePciMemAndBusMaster(b, d, f);
                const bars = pcie.decodePciBars(b, d, f);
                const mmio = firstMmioBar(bars) orelse continue;
                if (n < out.len) {
                    out[n] = .{
                        .loc = .{ .bus = b, .dev = d, .func = f },
                        .mmio = mmio,
                    };
                    n += 1;
                }
            }
        }
    }
    return n;
}

pub fn probeAndLog(max_bus: u8) void {
    var buf: [4]VirtioNetPciDev = undefined;
    const c = collectVirtioNetPci(buf[0..], max_bus);
    if (c == 0) {
        klog.info("VirtIO-Net: no 1af4:1000 in bus 0..%u (H4: 描述符环/MMIO 驱动后续)", .{max_bus});
        return;
    }
    minimal_stack.noteVirtioNetPciEnumerated(c);
    var i: usize = 0;
    while (i < c) : (i += 1) {
        const e = buf[i];
        klog.info("VirtIO-Net: %u:%u.%u MMIO phys=0x%x size=0x%x (ARP/IPv4/ICMP/UDP 见 net/minimal_stack.zig)", .{
            e.loc.bus,
            e.loc.dev,
            e.loc.func,
            e.mmio.base,
            e.mmio.size,
        });
    }
}
