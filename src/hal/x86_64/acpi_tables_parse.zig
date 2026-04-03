// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/acpi_tables_parse.zig
// Purpose: ACPI 表字节布局解析与校验和（**无** klog），供 `acpi_core.zig` 与主机黄金测共用。
//
// This is an independent clean-room implementation.
// Reference: ACPI 6.x §5.2.5 (checksum), §5.2.9 (FADT), HPET ACPI table.

const std = @import("std");

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

comptime {
    std.debug.assert(FadtLegacyLayout.reset_register_gas + 12 == FadtLegacyLayout.reset_value);
}

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

fn u32ToIoPort(v: u32) u16 {
    if (v == 0 or v > 0xffff) return 0;
    return @truncate(v);
}

pub fn parseFacpPmRegs(h: [*]align(1) const u8, len: u32) FadtPmRegs {
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

pub fn parseMcfg(h: [*]align(1) const u8, len: u32) ?McfgInfo {
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

pub fn parseHpetMmioPhys(h: [*]align(1) const u8, len: u32) ?u64 {
    if (!std.mem.eql(u8, h[0..4], "HPET")) return null;
    if (len < 52) return null;
    const gas_off = HpetTableLayout.base_address_gas;
    const space_id = readU8(h, gas_off);
    const addr = readU64(h, gas_off + 4);
    if (addr == 0) return null;
    if (space_id == 0) return addr;
    return null;
}

test "ACPI standard header checksum byte at offset 9" {
    var t: [40]u8 = [_]u8{0} ** 40;
    @memcpy(t[0..4], "TEST");
    std.mem.writeInt(u32, t[4..8], 40, .little);
    t[8] = 1; // revision
    t[9] = 0; // checksum — 填全表后写回
    var s: u32 = 0;
    for (t) |b| s +%= b;
    t[9] = @as(u8, 0) -% @as(u8, @truncate(s));
    try std.testing.expect(acpiTableBytesChecksumOk(@ptrCast(&t), 40));
}

fn patchAcpiTableChecksum(buf: []u8) void {
    buf[9] = 0;
    var s: u32 = 0;
    for (buf) |b| s +%= b;
    buf[9] = @as(u8, 0) -% @as(u8, @truncate(s));
}

fn patchRsdp20(buf: *[20]u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..8], rsdp_sig[0..8]);
    buf[15] = 0;
    std.mem.writeInt(u32, buf[16..20], 0xDEAD0000, .little);
    var s: u32 = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) s +%= buf[i];
    buf[8] = @as(u8, 0) -% @as(u8, @truncate(s));
}

// I9：FACP/HPET/MCFG/RSDP 黄金路径（与 `tests/acpi_fadt_pm1a_host.zig` 互补）。
test "RSDP v1 20-byte checksum" {
    var rsdp: [20]u8 = undefined;
    patchRsdp20(&rsdp);
    try std.testing.expect(rsdpStructureOk(@ptrCast(&rsdp)));
}

test "FACP legacy PM1a_CNT parse with valid table checksum" {
    var facp: [140]u8 = [_]u8{0} ** 140;
    @memcpy(facp[0..4], "FACP");
    std.mem.writeInt(u32, facp[4..8], 140, .little);
    facp[8] = 2;
    std.mem.writeInt(u32, facp[FadtLegacyLayout.pm1a_cnt_blk..][0..4], 0xB004, .little);
    patchAcpiTableChecksum(&facp);
    try std.testing.expect(acpiTableBytesChecksumOk(@ptrCast(&facp), 140));
    const pm = parseFacpPmRegs(@ptrCast(&facp), 140);
    try std.testing.expectEqual(@as(u16, 0xB004), pm.pm1a_cnt_io);
}

test "HPET table GAS MMIO base" {
    var ht: [56]u8 = [_]u8{0} ** 56;
    @memcpy(ht[0..4], "HPET");
    std.mem.writeInt(u32, ht[4..8], 56, .little);
    ht[8] = 1;
    const gas = HpetTableLayout.base_address_gas;
    ht[gas] = 0;
    std.mem.writeInt(u64, ht[gas + 4 ..][0..8], 0xFED0_1234, .little);
    patchAcpiTableChecksum(&ht);
    try std.testing.expectEqual(@as(?u64, 0xFED0_1234), parseHpetMmioPhys(@ptrCast(&ht), 56));
}

test "MCFG first segment parse" {
    var mc: [64]u8 = [_]u8{0} ** 64;
    @memcpy(mc[0..4], "MCFG");
    std.mem.writeInt(u32, mc[4..8], 64, .little);
    std.mem.writeInt(u64, mc[44..52], 0xE000_0000, .little);
    mc[54] = 0;
    mc[55] = 255;
    patchAcpiTableChecksum(&mc);
    const m = parseMcfg(@ptrCast(&mc), 64).?;
    try std.testing.expectEqual(@as(u64, 0xE000_0000), m.base_phys);
    try std.testing.expectEqual(@as(u8, 0), m.bus_lo);
    try std.testing.expectEqual(@as(u8, 255), m.bus_hi);
}
