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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/acpi_core.zig
// Purpose: **单一 ACPI 引导入口**：RSDP → XSDT/RSDT → 表头校验和 → 分发 MCFG/FACP/HPET/APIC；记录 DSDT 指针（**不**解析 AML）。解析算法见 `acpi_tables_parse.zig`。
//
// This is an independent clean-room implementation.
// Reference: ACPI 6.x — RSDP, root system description tables, FADT, HPET, MADT, MCFG.

const std = @import("std");
const parse = @import("acpi_tables_parse.zig");
const klog = @import("../../rtl/klog.zig");

pub const rsdp_sig = parse.rsdp_sig;
pub const FadtLegacyLayout = parse.FadtLegacyLayout;
pub const HpetTableLayout = parse.HpetTableLayout;
pub const McfgInfo = parse.McfgInfo;
pub const FadtPmRegs = parse.FadtPmRegs;

fn readU32(p: [*]align(1) const u8, off: usize) u32 {
    return std.mem.readInt(u32, p[off..][0..4], .little);
}

fn readU64(p: [*]align(1) const u8, off: usize) u64 {
    return std.mem.readInt(u64, p[off..][0..8], .little);
}

fn rootTablePhysFromRsdp(rsdp: [*]align(1) const u8) ?u64 {
    const rev = rsdp[15];
    const rsdt = readU32(rsdp, 16);
    if (rev >= 2) {
        const xsdt = readU64(rsdp, 24);
        if (xsdt != 0) return xsdt;
    }
    if (rsdt != 0) return @as(u64, rsdt);
    return null;
}

/// 上次成功遍历使用的 RSDP 物理址；同址重复 `initFromRsdp` 为 no-op（避免 PCI/MADT 双初始化清空状态）。
var g_rsdp_last: usize = 0;

/// 引导完成后只读快照（`initFromRsdp` 填充）。
pub var g_madt_phys: u64 = 0;
pub var g_facp_phys: u64 = 0;
pub var g_mcfg: McfgInfo = .{};
pub var g_fadt: FadtPmRegs = .{};
pub var g_hpet_mmio_phys: u64 = 0;
pub var g_rsdp_ok: bool = false;

pub fn acpiTableBytesChecksumOk(p: [*]align(1) const u8, len: usize) bool {
    return parse.acpiTableBytesChecksumOk(p, len);
}

pub fn rsdpStructureOk(p: [*]align(1) const u8) bool {
    return parse.rsdpStructureOk(p);
}

pub fn dsdtPhys() u32 {
    return g_fadt.dsdt_phys;
}

pub fn pm1aControlIoPort() u16 {
    return g_fadt.pm1a_cnt_io;
}

pub fn pm1bControlIoPort() u16 {
    return g_fadt.pm1b_cnt_io;
}

pub fn hpetMmioPhysOrZero() u64 {
    return g_hpet_mmio_phys;
}

pub fn fadtSnapshot() FadtPmRegs {
    return g_fadt;
}

fn walkAndDispatch(root_phys: u64) void {
    const rh: [*]align(1) const u8 = @ptrFromInt(@as(usize, @truncate(root_phys)));
    var sig: [4]u8 = undefined;
    @memcpy(sig[0..4], rh[0..4]);
    const len = readU32(rh, 4);
    if (len < 40 or len > 0x0100_0000) {
        klog.warn("ACPI core: root table @0x%x bad length %u", .{ root_phys, len });
        return;
    }
    if (!parse.acpiTableBytesChecksumOk(rh, len)) {
        klog.warn("ACPI core: root table @0x%x checksum fail", .{root_phys});
        return;
    }

    const dispatch = struct {
        fn one(ent_phys: u64) void {
            if (ent_phys == 0) return;
            const h: [*]align(1) const u8 = @ptrFromInt(@as(usize, @truncate(ent_phys)));
            const tl = readU32(h, 4);
            if (tl < 36 or tl > 0x0100_0000) return;
            if (!parse.acpiTableBytesChecksumOk(h, tl)) {
                klog.warn("ACPI core: table @0x%x bad checksum (skip)", .{ent_phys});
                return;
            }
            if (std.mem.eql(u8, h[0..4], "MCFG")) {
                if (parse.parseMcfg(h, tl)) |m| {
                    g_mcfg = m;
                    klog.info("ACPI core: MCFG ECAM base=0x%x buses %u..%u", .{
                        m.base_phys, m.bus_lo, m.bus_hi,
                    });
                }
            } else if (std.mem.eql(u8, h[0..4], "FACP")) {
                g_facp_phys = ent_phys;
                g_fadt = parse.parseFacpPmRegs(h, tl);
                klog.info("ACPI core: FADT PM1a_CNT=0x%x PM1b_CNT=0x%x SCI=%u DSDT=0x%x", .{
                    g_fadt.pm1a_cnt_io,
                    g_fadt.pm1b_cnt_io,
                    g_fadt.sci_interrupt,
                    g_fadt.dsdt_phys,
                });
            } else if (std.mem.eql(u8, h[0..4], "APIC")) {
                g_madt_phys = ent_phys;
                klog.info("ACPI core: MADT (APIC) @0x%x", .{ent_phys});
            } else if (std.mem.eql(u8, h[0..4], "HPET")) {
                if (parse.parseHpetMmioPhys(h, tl)) |mmio| {
                    g_hpet_mmio_phys = mmio;
                    klog.info("ACPI core: HPET MMIO phys=0x%x (表优先于常量 0xFED00000)", .{mmio});
                }
            } else if (std.mem.eql(u8, h[0..4], "DSDT")) {
                klog.info("ACPI core: XSDT/RSDT lists DSDT @0x%x (AML deferred)", .{ent_phys});
            }
        }
    }.one;

    if (std.mem.eql(u8, sig[0..4], "XSDT")) {
        const n = (len - 36) / 8;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dispatch(readU64(rh, 36 + i * 8));
        }
    } else if (std.mem.eql(u8, sig[0..4], "RSDT")) {
        const n = (len - 36) / 4;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dispatch(@as(u64, readU32(rh, 36 + i * 4)));
        }
    } else {
        klog.warn("ACPI core: unknown root signature {s}", .{sig[0..4]});
    }
}

/// Multiboot2 **RSDP 物理地址**（内核早期恒等映射可见）。须先于 `acpi_pci_early.loadFromAcpiCore` / `madt.loadFromAcpiCore` 调用。
pub fn initFromRsdp(rsdp_phys: usize) void {
    if (rsdp_phys != 0 and rsdp_phys == g_rsdp_last and g_rsdp_ok) return;
    g_rsdp_last = rsdp_phys;

    g_rsdp_ok = false;
    g_madt_phys = 0;
    g_facp_phys = 0;
    g_mcfg = .{};
    g_fadt = .{};
    g_hpet_mmio_phys = 0;

    if (rsdp_phys == 0) return;
    const p: [*]align(1) const u8 = @ptrFromInt(rsdp_phys);
    if (!parse.rsdpStructureOk(p)) {
        klog.warn("ACPI core: RSDP @0x%x signature or checksum invalid", .{rsdp_phys});
        return;
    }
    g_rsdp_ok = true;
    const root = rootTablePhysFromRsdp(p) orelse {
        klog.warn("ACPI core: no XSDT/RSDT pointer", .{});
        return;
    };
    walkAndDispatch(root);
}
