// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/acpi_pci_early.zig
// Purpose: 自 Multiboot2 提供的 RSDP 解析 XSDT/RSDT 并定位 MCFG，记录 PCIe ECAM；提供 MMIO `configRead32`。
//
// This is an independent clean-room implementation.
// Reference: ACPI spec (RSDP, XSDT, MCFG); PCI Express ECAM layout. No Windows/ReactOS code.

const std = @import("std");
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
    if (len < 40) return;

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
}

pub fn configRead32(bus: u8, dev: u8, func: u8, reg: u8) u32 {
    if (ecam_base_phys == 0) return 0xffff_ffff;
    if (bus < ecam_bus_lo or bus > ecam_bus_hi) return 0xffff_ffff;
    const r = reg & 0xfc;
    const off: u64 = (@as(u64, bus - ecam_bus_lo) << 20) |
        (@as(u64, dev & 0x1f) << 15) |
        (@as(u64, func & 7) << 12) |
        @as(u64, r);
    const addr = ecam_base_phys + off;
    const ptr: *align(1) const u32 = @ptrFromInt(@as(usize, @truncate(addr)));
    return ptr.*;
}

pub fn hasEcam() bool {
    return ecam_base_phys != 0;
}
