// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/storage/ahci.zig
// Purpose: PCI 发现 SATA AHCI 控制器（class 0x01/0x06/0x01）、解析 ABAR（典型为 BAR5）；为 HBA 命令/DMA 与 VFS 卷挂载预留接线点。
//
// This is an independent clean-room implementation.
// Reference: Serial ATA AHCI 1.3.1 specification (ABAR memory register block); PCI class codes — PCI-SIG.
// Milestone: docs/cn/PHASE4_HARDWARE_SYSTEM_INTEGRATION.md — 存储总线枚举。

const pcie = @import("../bus/pcie.zig");
const pci_bind = @import("../bus/pci_driver_bind.zig");
const klog = @import("../../rtl/klog.zig");

pub const AhciPciDev = struct {
    loc: pcie.PciLoc,
    vendor_id: u16,
    device_id: u16,
    /// AHCI 寄存器块物理基址（通常为 PCI BAR5 MMIO）。
    abar_phys: u64,
    abar_size: u64,
};

/// 选取 ABAR：优先 **BAR5** 非 I/O、非零且尺寸合理；否则首个满足条件的 MMIO BAR。
fn pickAbar(bars: [6]pcie.PciBarResource) ?pcie.PciBarResource {
    const b5 = bars[5];
    if (!b5.is_io and b5.base != 0 and b5.size >= 0x1000) return b5;
    for (bars) |bar| {
        if (!bar.is_io and bar.base != 0 and bar.size >= 0x1000) return bar;
    }
    return null;
}

/// 扫描 `0..max_bus`，收集 AHCI 控制器；每项启用 MEM+BusMaster 并解码 BAR。
pub fn collectAhciPci(out: []AhciPciDev, max_bus: u8) usize {
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
                if (pci_bind.lookupFromConfigClassWord(vid, did, cls) != .ahci) continue;

                pcie.enablePciMemAndBusMaster(b, d, f);
                const bars = pcie.decodePciBars(b, d, f);
                const abar = pickAbar(bars) orelse continue;
                if (n < out.len) {
                    out[n] = .{
                        .loc = .{ .bus = b, .dev = d, .func = f },
                        .vendor_id = vid,
                        .device_id = did,
                        .abar_phys = abar.base,
                        .abar_size = abar.size,
                    };
                    n += 1;
                }
            }
        }
    }
    return n;
}

/// 启动路径诊断：发现即打一条串口日志（**不**映射 MMIO、**不**发命令）。
pub fn probeAndLog(max_bus: u8) void {
    var buf: [8]AhciPciDev = undefined;
    const c = collectAhciPci(buf[0..], max_bus);
    if (c == 0) {
        klog.info("AHCI: no PCI AHCI controller in bus 0..%u", .{max_bus});
        return;
    }
    var i: usize = 0;
    while (i < c) : (i += 1) {
        const e = buf[i];
        klog.info("AHCI: %u:%u.%u VID:DID=0x%x:0x%x ABAR phys=0x%x size=0x%x (VFS/DMA 后续里程碑)", .{
            e.loc.bus,
            e.loc.dev,
            e.loc.func,
            e.vendor_id,
            e.device_id,
            e.abar_phys,
            e.abar_size,
        });
    }
}

/// H2：在 `probeAndLog` 已发现控制器后登记 VFS/卷挂载意图（DMA/IDENTIFY 就绪后再接 `vfs.mount`）。
pub fn noteVfsVolumeIntentAfterProbe(max_bus: u8) void {
    var buf: [8]AhciPciDev = undefined;
    const c = collectAhciPci(buf[0..], max_bus);
    if (c == 0) return;
    klog.info("AHCI: VFS volume wiring (H2): %u controller(s) pending block ops + mount", .{c});
}
