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
// Host test: ZOSH1 bootstrap record layout (must stay in sync with registry.mergeFromZosh1Bytes).

const std = @import("std");

fn readU16Le(data: []const u8, off: *usize) ?u16 {
    if (off.* + 2 > data.len) return null;
    const v = std.mem.readInt(u16, data[off.*..][0..2], .little);
    off.* += 2;
    return v;
}

fn readU32Le(data: []const u8, off: *usize) ?u32 {
    if (off.* + 4 > data.len) return null;
    const v = std.mem.readInt(u32, data[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

/// Parse first REG_DWORD record from ZOSH1 (smoke: keeps `registry.zig` merge format honest).
fn firstDwordRecord(data: []const u8) ?struct { path: []const u8, name: []const u8, value: u32 } {
    if (data.len < 8) return null;
    if (!std.mem.eql(u8, data[0..5], "ZOSH1")) return null;
    if (data[5] != 1) return null;
    var off: usize = 8;
    const nrec = readU16Le(data, &off) orelse return null;
    if (nrec < 1) return null;
    const plen = readU16Le(data, &off) orelse return null;
    if (off + plen > data.len) return null;
    const pth = data[off .. off + plen];
    off += plen;
    const nlen = readU16Le(data, &off) orelse return null;
    if (off + nlen > data.len) return null;
    const vname = data[off .. off + nlen];
    off += nlen;
    if (off >= data.len) return null;
    if (data[off] != 4) return null;
    off += 1;
    const dv = readU32Le(data, &off) orelse return null;
    return .{ .path = pth, .name = vname, .value = dv };
}

test "ZOSH1 first dword record round-trip bytes" {
    var buf: [256]u8 = undefined;
    const path = "\\Registry\\User\\Control Panel\\Mouse";
    const vname = "MouseSensitivity";
    @memcpy(buf[0..5], "ZOSH1");
    buf[5] = 1;
    buf[6] = 0;
    buf[7] = 0;
    var pos: usize = 8;
    std.mem.writeInt(u16, buf[pos..][0..2], 1, .little);
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(path.len), .little);
    pos += 2;
    @memcpy(buf[pos..][0..path.len], path);
    pos += path.len;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(vname.len), .little);
    pos += 2;
    @memcpy(buf[pos..][0..vname.len], vname);
    pos += vname.len;
    buf[pos] = 4;
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 12, .little);
    pos += 4;

    const rec = firstDwordRecord(buf[0..pos]).?;
    try std.testing.expectEqualStrings(path, rec.path);
    try std.testing.expectEqualStrings(vname, rec.name);
    try std.testing.expectEqual(@as(u32, 12), rec.value);
}
