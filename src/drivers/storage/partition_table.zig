// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/storage/partition_table.zig
// Purpose: **MBR** 与 **GPT**（含 protective MBR）解析子集；供 AHCI/VFS 卷 LBA 起点推导。
//
// Ref: UEFI GPT 规范；Microsoft 基本磁盘布局公开描述；OSDev MBR/GPT。

const std = @import("std");

pub const PartitionSlice = struct {
    start_lba: u64,
    size_lba: u64,
};

pub const GptHeaderMeta = struct {
    partition_entry_lba: u64,
    partition_entry_count: u32,
    partition_entry_size: u32,
};

const mbr_sig_off: usize = 510;
const gpt_sig = "EFI PART";

fn readU32le(slice: []const u8, off: usize) ?u32 {
    if (off + 4 > slice.len) return null;
    return std.mem.readInt(u32, slice[off..][0..4], .little);
}

fn readU64le(slice: []const u8, off: usize) ?u64 {
    if (off + 8 > slice.len) return null;
    return std.mem.readInt(u64, slice[off..][0..8], .little);
}

/// 512 字节 MBR 扇区：若 **分区类型 0xEE** 则视为 GPT protective MBR。
pub fn isGptProtectiveMbr(mbr512: *const [512]u8) bool {
    if (mbr512[mbr_sig_off] != 0x55 or mbr512[mbr_sig_off + 1] != 0xAA) return false;
    const t = mbr512[450];
    return t == 0xEE;
}

/// 经典 MBR：返回 **首个** 非空、类型非 0xEE/0x00 分区的起止 LBA（起始为 **CHS 布局后的 u32 LBA**）。
pub fn firstMbrPartition(mbr512: *const [512]u8) ?PartitionSlice {
    if (mbr512[mbr_sig_off] != 0x55 or mbr512[mbr_sig_off + 1] != 0xAA) return null;
    if (isGptProtectiveMbr(mbr512)) return null;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const off: usize = 446 + i * 16;
        const typ = mbr512[off + 4];
        if (typ == 0 or typ == 0xEE) continue;
        const start = readU32le(mbr512[0..], off + 8) orelse return null;
        const size = readU32le(mbr512[0..], off + 12) orelse return null;
        if (size == 0) continue;
        return .{ .start_lba = start, .size_lba = size };
    }
    return null;
}

/// GPT 头（LBA1）关键字段；`header512` 须为完整 512 字节扇区。
pub fn parseGptHeaderMeta(header512: *const [512]u8) ?GptHeaderMeta {
    if (!std.mem.eql(u8, header512[0..8], gpt_sig)) return null;
    return .{
        .partition_entry_lba = readU64le(header512[0..], 72) orelse return null,
        .partition_entry_count = readU32le(header512[0..], 80) orelse return null,
        .partition_entry_size = readU32le(header512[0..], 84) orelse return null,
    };
}

/// GPT 头扇区（通常 LBA1）与 **单扇区**分区表镜像的前 128 字节项 #0。
pub fn firstGptPartitionFromHeaderAndTable(
    header512: *const [512]u8,
    table512: *const [512]u8,
) ?PartitionSlice {
    if (!std.mem.eql(u8, header512[0..8], gpt_sig)) return null;
    const entry_size = readU32le(header512[0..], 84) orelse return null;
    if (entry_size < 128 or entry_size > 512) return null;
    // 首项 @ 表扇区偏移 0
    const ent = table512[0..entry_size];
    if (ent.len < 32) return null;
    const typ_low = readU64le(ent, 0) orelse return null;
    const typ_high = readU64le(ent, 8) orelse return null;
    if (typ_low == 0 and typ_high == 0) return null;
    const first_lba = readU64le(ent, 32) orelse return null;
    const last_lba = readU64le(ent, 40) orelse return null;
    if (last_lba < first_lba) return null;
    return .{ .start_lba = first_lba, .size_lba = last_lba - first_lba + 1 };
}

test "protective MBR + GPT first entry" {
    var mbr: [512]u8 = [_]u8{0} ** 512;
    mbr[450] = 0xEE;
    mbr[510] = 0x55;
    mbr[511] = 0xAA;
    try std.testing.expect(isGptProtectiveMbr(&mbr));
    try std.testing.expect(firstMbrPartition(&mbr) == null);

    var gh: [512]u8 = [_]u8{0} ** 512;
    @memcpy(gh[0..8], gpt_sig);
    std.mem.writeInt(u32, gh[84..][0..4], 128, .little);

    var te: [512]u8 = [_]u8{0} ** 512;
    std.mem.writeInt(u64, te[32..][0..8], 2048, .little);
    std.mem.writeInt(u64, te[40..][0..8], 4096, .little);
    te[0] = 0x01;

    const p = firstGptPartitionFromHeaderAndTable(&gh, &te).?;
    try std.testing.expectEqual(@as(u64, 2048), p.start_lba);
    try std.testing.expectEqual(@as(u64, 2049), p.size_lba);
}

test "MBR first partition" {
    var m: [512]u8 = [_]u8{0} ** 512;
    m[446 + 4] = 0x07;
    std.mem.writeInt(u32, m[446 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, m[446 + 12 ..][0..4], 100000, .little);
    m[510] = 0x55;
    m[511] = 0xAA;
    const p = firstMbrPartition(&m).?;
    try std.testing.expectEqual(@as(u64, 2048), p.start_lba);
    try std.testing.expectEqual(@as(u64, 100000), p.size_lba);
}
