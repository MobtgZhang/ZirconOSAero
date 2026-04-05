// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/registry/regf_parse.zig
// Purpose: Windows 注册表 **RegF** 磁盘 hive 的只读识别与 **HBIN/NK/VK** 子集解析入口（clean-room）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/windows/win32/sysinfo/registry-hives (概念层);
//      公开资料中 hive 文件头 / bin 容器描述（非实现拷贝）。

const std = @import("std");

pub const regf_magic = "regf";
pub const hbin_magic = "hbin";

/// 最小解析器已可用（魔数 + 首个 `hbin` 定位）；完整 NK/VK 链遍历仍渐进扩展。
pub fn minimalParserReady() bool {
    return true;
}

/// 识别缓冲区是否以 **regf** 基块开头（不要求 4KiB 对齐后的全块校验）。
pub fn regfHeaderOk(slice: []const u8) bool {
    return slice.len >= 4 and std.mem.eql(u8, slice[0..4], regf_magic);
}

/// 自 hive 映像定位 **首个** `hbin`（常见布局：基块后 4KiB）；若魔数不匹配返回 `null`。
/// 安全：仅读 `slice`；不解引用用户 VA。
pub fn firstHbinOffset(slice: []const u8) ?u32 {
    if (slice.len < 0x1004) return null;
    if (!std.mem.eql(u8, slice[0x1000..][0..4], hbin_magic)) return null;
    return 0x1000;
}

/// Hive **cell** 首 4 字节为有符号小端长度；取绝对值即为数据区大小（公开格式摘要）。
pub fn cellSizeMagnitude(slice: []const u8, offset: u32) ?u32 {
    const o: usize = @intCast(offset);
    if (o + 4 > slice.len) return null;
    const raw = std.mem.readInt(i32, slice[o..][0..4], .little);
    const mag = @abs(raw);
    if (mag < 8) return null;
    return @intCast(mag);
}

/// **NK**（键节点）与 **VK**（值节点）签名字节（公开头文件 / 规范摘要中的 ASCII 标记）。
pub const nk_sig = "nk";
pub const vk_sig = "vk";
pub const lf_sig = "lf";

/// 若 cell 内偏移 4..6 为 `nk`，返回 `true`（需 `cellSizeMagnitude` ≥ 头长）。
pub fn cellLooksLikeKeyNode(slice: []const u8, cell_offset: u32) bool {
    const sz = cellSizeMagnitude(slice, cell_offset) orelse return false;
    if (sz < 16) return false;
    const o: usize = @intCast(cell_offset);
    if (o + 6 > slice.len) return false;
    return std.mem.eql(u8, slice[o + 4 .. o + 6], nk_sig);
}

/// 若 cell 内偏移 4..6 为 `vk`，返回 `true`。
pub fn cellLooksLikeValueNode(slice: []const u8, cell_offset: u32) bool {
    const sz = cellSizeMagnitude(slice, cell_offset) orelse return false;
    if (sz < 16) return false;
    const o: usize = @intCast(cell_offset);
    if (o + 6 > slice.len) return false;
    return std.mem.eql(u8, slice[o + 4 .. o + 6], vk_sig);
}

/// **lf**（子键列表）cell：公开 RegF 摘要格式 — `u16` 计数后每条目 `u32` 哈希 + `u32` 子 **nk** cell 偏移。
pub fn lfSubkeyNkOffsets(slice: []const u8, lf_cell_off: u32, scratch: []u32) usize {
    const sz = cellSizeMagnitude(slice, lf_cell_off) orelse return 0;
    if (sz < 8) return 0;
    const o: usize = @intCast(lf_cell_off);
    if (o + 8 > slice.len) return 0;
    if (!std.mem.eql(u8, slice[o + 4 .. o + 6], lf_sig)) return 0;
    const count = std.mem.readInt(u16, slice[o + 6 ..][0..2], .little);
    var n: usize = 0;
    var i: u16 = 0;
    var base = o + 8;
    while (i < count and n < scratch.len) : (i += 1) {
        if (base + 8 > slice.len) break;
        scratch[n] = std.mem.readInt(u32, slice[base + 4 ..][0..4], .little);
        n += 1;
        base += 8;
    }
    return n;
}

/// **单测 / 教学习 fixture**：假定 nk cell 在偏移 **72** 起为 **ASCII** 名（非商业 hive 布局）；仅用于 `regf_parse` 主机测。
pub fn nkKeyNameAsciiFixture(slice: []const u8, nk_cell_off: u32) ?[]const u8 {
    if (!cellLooksLikeKeyNode(slice, nk_cell_off)) return null;
    const o: usize = @intCast(nk_cell_off);
    if (o + 80 > slice.len) return null;
    const nl = std.mem.readInt(u16, slice[o + 72 ..][0..2], .little);
    if (nl == 0 or o + 74 + nl > slice.len) return null;
    return slice[o + 74 .. o + 74 + nl];
}

/// **fixture**：`vk` 内联 **REG_DWORD** — 假定 `u16` 类型在 +12、`u32` 值在 +16（仅合成缓冲）。
pub fn vkDwordValueFixture(slice: []const u8, vk_cell_off: u32) ?u32 {
    if (!cellLooksLikeValueNode(slice, vk_cell_off)) return null;
    const o: usize = @intCast(vk_cell_off);
    if (o + 24 > slice.len) return null;
    const ty = std.mem.readInt(u16, slice[o + 12 ..][0..2], .little);
    if (ty != 4) return null; // REG_DWORD
    return std.mem.readInt(u32, slice[o + 16 ..][0..4], .little);
}

test "regf magic and hbin offset" {
    var buf: [8192]u8 = [_]u8{0} ** 8192;
    @memcpy(buf[0..4], regf_magic);
    @memcpy(buf[0x1000..][0..4], hbin_magic);
    try std.testing.expect(regfHeaderOk(&buf));
    try std.testing.expectEqual(@as(?u32, 0x1000), firstHbinOffset(&buf));
}

test "cell size magnitude" {
    var cell: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(i32, cell[0..4], -32, .little);
    try std.testing.expectEqual(@as(?u32, 32), cellSizeMagnitude(&cell, 0));
}

test "nk / vk sig at +4" {
    var nk: [24]u8 = [_]u8{0} ** 24;
    std.mem.writeInt(i32, nk[0..4], -24, .little);
    @memcpy(nk[4..6], nk_sig);
    try std.testing.expect(cellLooksLikeKeyNode(&nk, 0));

    var vk: [24]u8 = [_]u8{0} ** 24;
    std.mem.writeInt(i32, vk[0..4], -24, .little);
    @memcpy(vk[4..6], vk_sig);
    try std.testing.expect(cellLooksLikeValueNode(&vk, 0));
}

test "lf subkey offsets and nk vk fixture walk" {
    var lf: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(i32, lf[0..4], -32, .little);
    @memcpy(lf[4..6], lf_sig);
    std.mem.writeInt(u16, lf[6..8], 1, .little);
    std.mem.writeInt(u32, lf[8..12], 0, .little);
    const child_off: u32 = 0x100;
    std.mem.writeInt(u32, lf[12..16], child_off, .little);

    var scratch: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), lfSubkeyNkOffsets(&lf, 0, scratch[0..]));
    try std.testing.expectEqual(child_off, scratch[0]);

    var nkcell: [96]u8 = [_]u8{0} ** 96;
    std.mem.writeInt(i32, nkcell[0..4], -96, .little);
    @memcpy(nkcell[4..6], nk_sig);
    const name = "Child";
    std.mem.writeInt(u16, nkcell[72..74], @intCast(name.len), .little);
    @memcpy(nkcell[74 .. 74 + name.len], name);

    try std.testing.expectEqualStrings(name, nkKeyNameAsciiFixture(&nkcell, 0).?);

    var vkcell: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(i32, vkcell[0..4], -32, .little);
    @memcpy(vkcell[4..6], vk_sig);
    std.mem.writeInt(u16, vkcell[12..14], 4, .little);
    std.mem.writeInt(u32, vkcell[16..20], 0x11223344, .little);
    try std.testing.expectEqual(@as(?u32, 0x11223344), vkDwordValueFixture(&vkcell, 0));
}
