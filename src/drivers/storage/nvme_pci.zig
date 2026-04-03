// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/storage/nvme_pci.zig
// Purpose: PCI 发现 NVM Express 控制器（class 0x01/0x08/0x02），记录 **BAR0**（规范中的寄存器/Doorbell 窗口基址，具体布局见 NVMe 规范）。
//
// This is an independent clean-room implementation.
// Reference: NVM Express Base Specification — PCI class code 010802; BAR0 为控制器寄存器块（本文件仅记录物理基址与尺寸）。
// Milestone: 与 `ahci.zig` 共享上层块设备抽象（后续）。

const pcie = @import("../bus/pcie.zig");
const pci_bind = @import("../bus/pci_driver_bind.zig");
const klog = @import("../../rtl/klog.zig");

pub const NvmePciDev = struct {
    loc: pcie.PciLoc,
    vendor_id: u16,
    device_id: u16,
    bar0_phys: u64,
    bar0_size: u64,
};

fn pickBar0(bars: [6]pcie.PciBarResource) ?pcie.PciBarResource {
    const b0 = bars[0];
    if (!b0.is_io and b0.base != 0 and b0.size >= 0x1000) return b0;
    for (bars) |bar| {
        if (!bar.is_io and bar.base != 0 and bar.size >= 0x1000) return bar;
    }
    return null;
}

pub fn collectNvmePci(out: []NvmePciDev, max_bus: u8) usize {
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
                if (pci_bind.lookupFromConfigClassWord(vid, did, cls) != .nvme) continue;

                pcie.enablePciMemAndBusMaster(b, d, f);
                const bars = pcie.decodePciBars(b, d, f);
                const bar0 = pickBar0(bars) orelse continue;
                if (n < out.len) {
                    out[n] = .{
                        .loc = .{ .bus = b, .dev = d, .func = f },
                        .vendor_id = vid,
                        .device_id = did,
                        .bar0_phys = bar0.base,
                        .bar0_size = bar0.size,
                    };
                    n += 1;
                }
            }
        }
    }
    return n;
}

pub fn probeAndLog(max_bus: u8) void {
    var buf: [8]NvmePciDev = undefined;
    const c = collectNvmePci(buf[0..], max_bus);
    if (c == 0) {
        klog.info("NVMe: no PCI NVMe controller in bus 0..%u", .{max_bus});
        return;
    }
    var i: usize = 0;
    while (i < c) : (i += 1) {
        const e = buf[i];
        klog.info("NVMe: %u:%u.%u VID:DID=0x%x:0x%x BAR0 phys=0x%x size=0x%x (Admin/IO 队列后续里程碑)", .{
            e.loc.bus,
            e.loc.dev,
            e.loc.func,
            e.vendor_id,
            e.device_id,
            e.bar0_phys,
            e.bar0_size,
        });
    }
}
