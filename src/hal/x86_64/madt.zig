// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/madt.zig
// Purpose: 自 ACPI RSDP 定位 **APIC**（MADT），枚举 Local APIC MMIO 基址与可用逻辑 CPU 数（SMP 前置）。
//
// This is an independent clean-room implementation.
// Reference: ACPI spec 5.x — MADT (APIC table); Intel SDM — local APIC. No Windows/ReactOS code.

const std = @import("std");
const klog = @import("../../rtl/klog.zig");

const rsdp_sig = "RSD PTR ";

fn readU32(p: [*]align(1) const u8, off: usize) u32 {
    return std.mem.readInt(u32, p[off..][0..4], .little);
}

fn readU64(p: [*]align(1) const u8, off: usize) u64 {
    return std.mem.readInt(u64, p[off..][0..8], .little);
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

/// Local APIC 寄存器区默认物理基址（MADT 可覆盖）；未解析成功时为 0xFEE00000。
pub var local_apic_mmio_phys: u32 = 0xFEE0_0000;

/// 自 MADT 中 **已启用** 的 Processor Local APIC 条目统计的逻辑 CPU 数（至少为 1）。
pub var logical_cpu_count: u32 = 1;

fn parseMadt(madt_phys: u64) void {
    const h: [*]align(1) const u8 = @ptrFromInt(@as(usize, @truncate(madt_phys)));
    if (!std.mem.eql(u8, h[0..4], "APIC")) return;
    const len = readU32(h, 4);
    if (len < 44) return;
    const lapic = readU32(h, 36);
    if (lapic != 0) local_apic_mmio_phys = lapic;

    var off: usize = 44;
    var cpus: u32 = 0;
    while (off + 2 <= len) {
        const typ = h[off];
        const elen = h[off + 1];
        if (elen < 2 or off + elen > len) break;
        if (typ == 0 and elen >= 8) {
            const flags = readU32(h, off + 4);
            if ((flags & 1) != 0) cpus += 1;
        }
        off += elen;
    }
    if (cpus >= 1) logical_cpu_count = cpus;
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
            if (ent != 0) parseMadt(ent);
        }
    } else if (std.mem.eql(u8, sig[0..4], "RSDT")) {
        const n = (len - 36) / 4;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ent32 = readU32(rh, 36 + i * 4);
            if (ent32 != 0) parseMadt(@as(u64, ent32));
        }
    }
}

/// `rsdp_phys`：恒等映射下 ACPI RSDP 物理地址（Multiboot2 tag 14/15）。
pub fn initFromRsdp(rsdp_phys: usize) void {
    const rsdp: [*]align(1) const u8 = @ptrFromInt(rsdp_phys);
    if (!std.mem.eql(u8, rsdp[0..8], rsdp_sig[0..8])) return;
    const root = rootTablePhys(rsdp) orelse return;
    walkRoot(root);
    klog.info("ACPI MADT: LAPIC MMIO phys=0x%x logical_cpus=%u", .{ local_apic_mmio_phys, logical_cpu_count });
}
