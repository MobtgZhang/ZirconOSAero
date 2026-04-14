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
// Module: src/hal/loongarch64/acpi_core.zig
// Purpose: LoongArch64 ACPI 引导入口。RSDP → XSDT/RSDT → 表头校验和 → 分发 MCFG/FACP/HPET/APIC；与 x86_64/acpi_core.zig 行为对齐，但独立实现。
//
// This is an independent clean-room implementation.
// Reference: ACPI 6.x — RSDP, root system description tables, FADT, HPET, MADT, MCFG.

const std = @import("std");
const klog = @import("../../rtl/klog.zig");

pub const rsdp_sig = "RSD PTR ";
pub const FadtLegacyLayout = struct {
    pub const oem_dsdt: usize = 40;
    pub const sci_interrupt: usize = 46;
    pub const pm1a_evt_blk: usize = 56;
    pub const pm1b_evt_blk: usize = 60;
    pub const pm1a_cnt_blk: usize = 64;
    pub const pm1b_cnt_blk: usize = 68;
    pub const reset_register_gas: usize = 116;
    pub const reset_value: usize = 128;
};
pub const HpetTableLayout = struct {
    pub const event_timer_block_id: usize = 36;
    pub const base_address_gas: usize = 40;
};
pub const McfgInfo = struct {
    base_phys: u64 = 0,
    segment: u16 = 0,
    bus_lo: u8 = 0,
    bus_hi: u8 = 0,
};
pub const FadtPmRegs = struct {
    dsdt_phys: u32 = 0,
    sci_interrupt: u16 = 0,
    pm1a_evt_io: u16 = 0,
    pm1b_evt_io: u16 = 0,
    pm1a_cnt_io: u16 = 0,
    pm1b_cnt_io: u16 = 0,
    reset_gas_space_id: u8 = 0,
    reset_gas_addr: u64 = 0,
    reset_value: u8 = 0,
};

fn readU8(p: [*]align(1) const u8, off: usize) u8 {
    return p[off];
}
fn readU16(p: [*]align(1) const u8, off: usize) u16 {
    return std.mem.readInt(u16, p[off..][0..2], .little);
}
fn readU32(p: [*]align(1) const u8, off: usize) u32 {
    return std.mem.readInt(u32, p[off..][0..4], .little);
}
fn readU64(p: [*]align(1) const u8, off: usize) u64 {
    return std.mem.readInt(u64, p[off..][0..8], .little);
}

pub fn acpiTableBytesChecksumOk(p: [*]align(1) const u8, len: usize) bool {
    if (len < 36) return false;
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        sum +%= p[i];
    }
    return @as(u8, @truncate(sum)) == 0;
}

pub fn rsdpStructureOk(p: [*]align(1) const u8) bool {
    if (!std.mem.eql(u8, p[0..8], rsdp_sig[0..8])) return false;
    var s20: u32 = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) s20 +%= p[i];
    if (@as(u8, @truncate(s20)) != 0) return false;
    const rev = p[15];
    if (rev < 2) return true;
    const total_len = readU32(p, 20);
    if (total_len < 36 or total_len > 0x1000) return false;
    var s2: u32 = 0;
    var j: usize = 0;
    while (j < total_len) : (j += 1) s2 +%= p[j];
    return @as(u8, @truncate(s2)) == 0;
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

var g_rsdp_last: usize = 0;
pub var g_madt_phys: u64 = 0;
pub var g_facp_phys: u64 = 0;
pub var g_mcfg: McfgInfo = .{};
pub var g_fadt: FadtPmRegs = .{};
pub var g_hpet_mmio_phys: u64 = 0;
pub var g_rsdp_ok: bool = false;

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

fn u32ToIoPort(v: u32) u16 {
    if (v == 0 or v > 0xffff) return 0;
    return @truncate(v);
}

fn parseFacpPmRegs(h: [*]align(1) const u8, len: u32) FadtPmRegs {
    var out: FadtPmRegs = .{};
    if (len < 116) return out;
    if (!std.mem.eql(u8, h[0..4], "FACP")) return out;
    out.dsdt_phys = readU32(h, FadtLegacyLayout.oem_dsdt);
    out.sci_interrupt = readU16(h, FadtLegacyLayout.sci_interrupt);
    out.pm1a_evt_io = u32ToIoPort(readU32(h, FadtLegacyLayout.pm1a_evt_blk));
    out.pm1b_evt_io = u32ToIoPort(readU32(h, FadtLegacyLayout.pm1b_evt_blk));
    out.pm1a_cnt_io = u32ToIoPort(readU32(h, FadtLegacyLayout.pm1a_cnt_blk));
    out.pm1b_cnt_io = u32ToIoPort(readU32(h, FadtLegacyLayout.pm1b_cnt_blk));
    if (len > FadtLegacyLayout.reset_value) {
        out.reset_gas_space_id = readU8(h, FadtLegacyLayout.reset_register_gas);
        out.reset_gas_addr = readU64(h, FadtLegacyLayout.reset_register_gas + 4);
        out.reset_value = readU8(h, FadtLegacyLayout.reset_value);
    }
    return out;
}

fn parseMcfg(h: [*]align(1) const u8, len: u32) ?McfgInfo {
    if (!std.mem.eql(u8, h[0..4], "MCFG")) return null;
    if (len < 44) return null;
    const base = readU64(h, 44);
    if (base == 0) return null;
    return .{
        .base_phys = base,
        .segment = readU16(h, 52),
        .bus_lo = h[54],
        .bus_hi = h[55],
    };
}

fn parseHpetMmioPhys(h: [*]align(1) const u8, len: u32) ?u64 {
    if (!std.mem.eql(u8, h[0..4], "HPET")) return null;
    if (len < 52) return null;
    const gas_off = HpetTableLayout.base_address_gas;
    const space_id = readU8(h, gas_off);
    const addr = readU64(h, gas_off + 4);
    if (addr == 0) return null;
    if (space_id == 0) return addr;
    return null;
}

fn walkAndDispatch(root_phys: u64) void {
    const rh: [*]align(1) const u8 = @ptrFromInt(@as(usize, @truncate(root_phys)));
    var sig: [4]u8 = undefined;
    @memcpy(sig[0..4], rh[0..4]);
    const len = readU32(rh, 4);
    if (len < 40 or len > 0x0100_0000) {
        klog.warn("LA ACPI: root table @0x%x bad length %u", .{ root_phys, len });
        return;
    }
    if (!acpiTableBytesChecksumOk(rh, len)) {
        klog.warn("LA ACPI: root table @0x%x checksum fail", .{root_phys});
        return;
    }

    const dispatch_one = struct {
        fn one(ent_phys: u64) void {
            if (ent_phys == 0) return;
            const h: [*]align(1) const u8 = @ptrFromInt(@as(usize, @truncate(ent_phys)));
            const tl = readU32(h, 4);
            if (tl < 36 or tl > 0x0100_0000) return;
            if (!acpiTableBytesChecksumOk(h, tl)) {
                klog.warn("LA ACPI: table @0x%x bad checksum (skip)", .{ent_phys});
                return;
            }
            if (std.mem.eql(u8, h[0..4], "MCFG")) {
                if (parseMcfg(h, tl)) |m| {
                    g_mcfg = m;
                    klog.info("LA ACPI: MCFG ECAM base=0x%x buses %u..%u", .{
                        m.base_phys, m.bus_lo, m.bus_hi,
                    });
                }
            } else if (std.mem.eql(u8, h[0..4], "FACP")) {
                g_facp_phys = ent_phys;
                g_fadt = parseFacpPmRegs(h, tl);
                klog.info("LA ACPI: FADT PM1a_CNT=0x%x PM1b_CNT=0x%x SCI=%u DSDT=0x%x", .{
                    g_fadt.pm1a_cnt_io,
                    g_fadt.pm1b_cnt_io,
                    g_fadt.sci_interrupt,
                    g_fadt.dsdt_phys,
                });
            } else if (std.mem.eql(u8, h[0..4], "APIC")) {
                g_madt_phys = ent_phys;
                klog.info("LA ACPI: MADT (APIC) @0x%x", .{ent_phys});
            } else if (std.mem.eql(u8, h[0..4], "HPET")) {
                if (parseHpetMmioPhys(h, tl)) |mmio| {
                    g_hpet_mmio_phys = mmio;
                    klog.info("LA ACPI: HPET MMIO phys=0x%x", .{mmio});
                }
            } else if (std.mem.eql(u8, h[0..4], "DSDT")) {
                klog.info("LA ACPI: XSDT/RSDT lists DSDT @0x%x (AML deferred)", .{ent_phys});
            }
        }
    }.one;

    if (std.mem.eql(u8, sig[0..4], "XSDT")) {
        const n = (len - 36) / 8;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dispatch_one(readU64(rh, 36 + i * 8));
        }
    } else if (std.mem.eql(u8, sig[0..4], "RSDT")) {
        const n = (len - 36) / 4;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dispatch_one(@as(u64, readU32(rh, 36 + i * 4)));
        }
    } else {
        klog.warn("LA ACPI: unknown root signature {s}", .{sig[0..4]});
    }
}

/// rsdp_phys: 从 UEFI handoff 或 RSDP 搜索协议获得的物理地址。
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
    if (!rsdpStructureOk(p)) {
        klog.warn("LA ACPI: RSDP @0x%x signature or checksum invalid", .{rsdp_phys});
        return;
    }
    g_rsdp_ok = true;
    const root = rootTablePhysFromRsdp(p) orelse {
        klog.warn("LA ACPI: no XSDT/RSDT pointer", .{});
        return;
    };
    walkAndDispatch(root);
}
