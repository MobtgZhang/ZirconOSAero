// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/redirect.zig
// Purpose: SysWOW64 风格文件路径与 `\Registry\Machine\SOFTWARE\` 逻辑重定向（可测子集）；行为级对照 Learn，独立实现。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows/win32/winprog64/file-system-redirector
// Ref: https://learn.microsoft.com/windows/win32/winprog64/shared-registry-keys

const std = @import("std");

fn utf16LeUnitAt(bytes: []const u8, wchar_index: usize) ?u16 {
    const off = wchar_index * 2;
    if (off + 2 > bytes.len) return null;
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn utf16LeUnitsEqlIgnoreCase(a: u16, b: u16) bool {
    return std.ascii.toLower(@truncate(a)) == std.ascii.toLower(@truncate(b));
}

/// 在 UTF-16LE 字节串中查找 `\System32\`（反斜杠 + 不区分大小写 `System32` + 反斜杠），返回 **起始反斜杠** 的字节偏移。
fn findSystem32SegmentUtf16Le(path_utf16_bytes: []const u8) ?usize {
    if (path_utf16_bytes.len < 20) return null;
    var i: usize = 0;
    while (i + 20 <= path_utf16_bytes.len) : (i += 2) {
        if (utf16LeUnitAt(path_utf16_bytes, i / 2) != '\\') continue;
        const s = i / 2 + 1;
        const letters = "System32";
        var ok = true;
        var k: usize = 0;
        while (k < letters.len) : (k += 1) {
            const u = utf16LeUnitAt(path_utf16_bytes, s + k) orelse {
                ok = false;
                break;
            };
            if (!utf16LeUnitsEqlIgnoreCase(u, letters[k])) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        const after = utf16LeUnitAt(path_utf16_bytes, s + letters.len) orelse continue;
        if (after != '\\') continue;
        return i;
    }
    return null;
}

/// 将 UTF-16LE 路径中的 **一段** `\System32\` 替换为 `\SysWOW64\`（同为 8 个 WCHAR，总长不变）。`dst` 须至少 `src.len` 字节。
/// 若 `is_wow64` 为 false 或未找到片段，返回 `null`（调用方沿用 `src`）。
pub fn applyWow64FilePathUtf16Le(is_wow64: bool, src: []const u8, dst: []u8) ?[]const u8 {
    if (!is_wow64) return null;
    const off = findSystem32SegmentUtf16Le(src) orelse return null;
    if (src.len > dst.len) return null;
    @memcpy(dst[0..src.len], src);
    // `\` at off, then 8 WCHARs System32, then `\` at off+18
    const inner_byte_off = off + 2;
    const repl = "SysWOW64";
    var c: usize = 0;
    while (c < repl.len) : (c += 1) {
        std.mem.writeInt(u16, dst[inner_byte_off + c * 2 ..][0..2], repl[c], .little);
    }
    return dst[0..src.len];
}

const reg_machine_software_prefix = "\\Registry\\Machine\\SOFTWARE\\";
const wow6432node_seg = "Wow6432Node\\";

/// 对窄字节（syscall 从 `UNICODE_STRING` 抽取后的 ASCII 子集）路径：在 `\Registry\Machine\SOFTWARE\` 下插入 `Wow6432Node\`（若尚未存在）。
pub fn applyWow64RegistryMachineSoftwarePath(is_wow64: bool, path: []const u8, out: []u8) ?[]const u8 {
    if (!is_wow64) return null;
    if (path.len < reg_machine_software_prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(path[0..reg_machine_software_prefix.len], reg_machine_software_prefix)) return null;
    const after = path[reg_machine_software_prefix.len..];
    if (after.len >= wow6432node_seg.len and
        std.ascii.eqlIgnoreCase(after[0..wow6432node_seg.len], wow6432node_seg)) return null;
    const new_len = reg_machine_software_prefix.len + wow6432node_seg.len + after.len;
    if (new_len > out.len) return null;
    @memcpy(out[0..reg_machine_software_prefix.len], reg_machine_software_prefix);
    @memcpy(out[reg_machine_software_prefix.len..][0..wow6432node_seg.len], wow6432node_seg);
    @memcpy(out[reg_machine_software_prefix.len + wow6432node_seg.len ..][0..after.len], after);
    return out[0..new_len];
}

/// 若路径（UTF-16 字节长度）可能含需检查的重定向片段，返回 true（供门禁 / 统计）。
pub fn shouldRedirectSystem32ToSyswow64(path_utf16_bytes_len: usize) bool {
    return path_utf16_bytes_len >= 20;
}

/// 注册表策略占位：保留符号供未来 Classes 等扩展；当前无操作。
pub fn noteRegistryWow64Node(_: []const u8) void {}

test "SysWOW64 redirect: UTF-16 System32 -> SysWOW64" {
    var path: [64]u8 = undefined;
    const lit = [_]u16{ 'C', ':', '\\', 'W', 'i', 'n', 'd', 'o', 'w', 's', '\\', 'S', 'y', 's', 't', 'e', 'm', '3', '2', '\\', 'x' };
    var o: usize = 0;
    for (lit) |ch| {
        std.mem.writeInt(u16, path[o..][0..2], ch, .little);
        o += 2;
    }
    const src = path[0..o];
    var dst: [64]u8 = undefined;
    const got = applyWow64FilePathUtf16Le(true, src, &dst) orelse return error.Fail;
    try std.testing.expectEqual(src.len, got.len);
    try std.testing.expect(findSystem32SegmentUtf16Le(got) == null);
    try std.testing.expect(utf16LeUnitAt(got, 14) == 'W');
    try std.testing.expect(utf16LeUnitAt(got, 15) == 'O');
    try std.testing.expect(utf16LeUnitAt(got, 16) == 'W');
}

test "registry SOFTWARE Wow6432Node insertion" {
    var buf: [256]u8 = undefined;
    const in_path = "\\Registry\\Machine\\SOFTWARE\\Microsoft\\X";
    const got = applyWow64RegistryMachineSoftwarePath(true, in_path, &buf) orelse return error.Fail;
    try std.testing.expect(std.mem.indexOf(u8, got, "Wow6432Node") != null);
    try std.testing.expect(applyWow64RegistryMachineSoftwarePath(true, got, &buf) == null);
}

test "SysWOW64 redirect placeholders conservative" {
    try std.testing.expect(!shouldRedirectSystem32ToSyswow64(0));
    try std.testing.expect(shouldRedirectSystem32ToSyswow64(64));
    noteRegistryWow64Node("Software\\Classes");
}
