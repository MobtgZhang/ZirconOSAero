// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/acpi_pci_early.zig
// Purpose: 自 Multiboot2 提供的 RSDP 解析 XSDT/RSDT 并定位 MCFG，记录 PCIe ECAM；提供 MMIO `configRead32`。
//
// This is an independent clean-room implementation.
// Reference: ACPI spec (RSDP, XSDT, MCFG); PCI Express ECAM layout. No Windows/ReactOS code.
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K3（表遍历、ECAM；AML 见延后项）。

const std = @import("std");
const ecam_layout = @import("ecam_layout.zig");
const klog = @import("../../rtl/klog.zig");

const rsdp_sig = "RSD PTR ";

var ecam_base_phys: u64 = 0;
var ecam_segment: u16 = 0;
var ecam_bus_lo: u8 = 0;
var ecam_bus_hi: u8 = 0;

fn readU32(p: [*]align(1) const u8, off: usize) u32 {
    return std.mem.readInt(u32, p[off..][0..4], .little);
}

fn readU64(p: [*]align(1) const u8, off: usize) u64 {
    return std.mem.readInt(u64, p[off..][0..8], .little);
}

fn readU16(p: [*]align(1) const u8, off: usize) u16 {
    return std.mem.readInt(u16, p[off..][0..2], .little);
}

fn rootTablePhys(rsdp: [*]align(1) const u8) ?u64 {
    const rev = rsdp[15];
    const rsdt = readU32(rsdp, 16);
    if (rev >= 2) {
        const xsdt = readU64(rsdp, 24);
        if (xsdt != 0) return xsdt;
    }
    if (rsdt != 0) return @as(u64, rsdt);
    return null;
}

fn tryParseMcfg(mcfg_phys: u64) bool {
    const h: [*]align(1) const u8 = @ptrFromInt(@as(usize, @truncate(mcfg_phys)));
    if (!std.mem.eql(u8, h[0..4], "MCFG")) return false;
    const tbl_len = readU32(h, 4);
    if (tbl_len < 44) return false;
    ecam_base_phys = readU64(h, 44);
    ecam_segment = readU16(h, 52);
    ecam_bus_lo = h[54];
    ecam_bus_hi = h[55];
    return ecam_base_phys != 0;
}

fn walkRoot(phys: u64) void {
    const rh: [*]align(1) const u8 = @ptrFromInt(@as(usize, @truncate(phys)));
    var sig: [4]u8 = undefined;
    @memcpy(sig[0..4], rh[0..4]);
    const len = readU32(rh, 4);
    // ACPI 表头最小 36 + 至少一项指针；过大则视为损坏，避免 walk 越界。
    if (len < 40 or len > 0x0100_0000) {
        if (len < 40) {
            klog.warn("ACPI: root table at 0x%x length %u too small", .{ phys, len });
        } else {
            klog.warn("ACPI: root table at 0x%x length %u suspicious (skipped)", .{ phys, len });
        }
        return;
    }

    if (std.mem.eql(u8, sig[0..4], "XSDT")) {
        const n = (len - 36) / 8;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ent = readU64(rh, 36 + i * 8);
            if (ent != 0 and tryParseMcfg(ent)) return;
        }
    } else if (std.mem.eql(u8, sig[0..4], "RSDT")) {
        const n = (len - 36) / 4;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ent32 = readU32(rh, 36 + i * 4);
            if (ent32 != 0 and tryParseMcfg(@as(u64, ent32))) return;
        }
    }
}

/// `rsdp_phys`：恒等映射下 ACPI RSDP 物理地址（Multiboot2 tag 14/15 内嵌体首址）。
pub fn initFromRsdp(rsdp_phys: usize) void {
    if (rsdp_phys == 0) return;
    const p: [*]align(1) const u8 = @ptrFromInt(rsdp_phys);
    // SAFETY: 指针来自引导信息，内核早期恒等映射已覆盖该低物理区。
    if (!std.mem.eql(u8, p[0..8], rsdp_sig)) {
        klog.warn("ACPI: invalid RSDP signature at 0x%x", .{rsdp_phys});
        return;
    }
    const root = rootTablePhys(p) orelse {
        klog.warn("ACPI: no RSDT/XSDT pointer", .{});
        return;
    };
    walkRoot(root);
    if (ecam_base_phys == 0) {
        klog.info("ACPI/PCI: MCFG not found (ECAM disabled)", .{});
        return;
    }
    klog.info("ACPI/PCI: ECAM base=0x%x seg=%u buses %u..%u", .{
        ecam_base_phys,
        ecam_segment,
        ecam_bus_lo,
        ecam_bus_hi,
    });
    const id_lo = configRead32(0, 0, 0, 0);
    klog.info("ACPI/PCI: cfg[0:0.0] vendor=0x%x device=0x%x", .{
        @as(u16, @truncate(id_lo & 0xffff)),
        @as(u16, @truncate(id_lo >> 16)),
    });
    if (DEBUG_MODE) logBus0Function0Snapshot();
}

const DEBUG_MODE = @import("build_options").debug;

/// Debug-only：枚举 PCI 总线 0、功能 0 上非空插槽（VID != 0xFFFF），为 XHCI/AHCI 等驱动接线提供早期拓扑线索。
fn logBus0Function0Snapshot() void {
    var present: u32 = 0;
    var d: u8 = 0;
    while (d < 32) : (d += 1) {
        const id = configRead32(0, d, 0, 0);
        const ven = @as(u16, @truncate(id & 0xffff));
        if (ven == 0xffff) continue;
        present += 1;
        if (present <= 12) {
            klog.debug("ACPI/PCI: bus0 dev%u func0 vid=0x%x did=0x%x", .{
                d,
                ven,
                @as(u16, @truncate(id >> 16)),
            });
        }
    }
    klog.debug("ACPI/PCI: bus0 function0 present count=%u (up to 12 logged)", .{present});
}

pub fn configRead32(bus: u8, dev: u8, func: u8, reg: u8) u32 {
    if (ecam_base_phys == 0) return 0xffff_ffff;
    if (bus < ecam_bus_lo or bus > ecam_bus_hi) return 0xffff_ffff;
    const off = ecam_layout.pciConfigDwordOffset(bus - ecam_bus_lo, dev, func, reg);
    const addr = ecam_base_phys + off;
    const ptr: *align(1) const u32 = @ptrFromInt(@as(usize, @truncate(addr)));
    return ptr.*;
}

pub fn hasEcam() bool {
    return ecam_base_phys != 0;
}
