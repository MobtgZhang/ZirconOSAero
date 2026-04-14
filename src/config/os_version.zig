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

//! Single source of truth for NT 6.1–style version numbers exposed to RtlGetVersion,
//! GetVersionEx*, and NtQuerySystemInformation(SystemVersionInformation).
//! Values default to embedded `system.conf`; before `config.init()`, compile-time defaults apply.

const config = @import("config.zig");

const default_major: u32 = 6;
const default_minor: u32 = 1;
const default_build: u32 = 7601;

fn parseVersionTriplet(v: []const u8) struct { major: u32, minor: u32, build: u32 } {
    var maj = default_major;
    var min = default_minor;
    var bld = default_build;
    if (v.len == 0) return .{ .major = maj, .minor = min, .build = bld };

    var part: u32 = 0;
    var section: u8 = 0; // 0 = major, 1 = minor, 2 = build

    for (v) |ch| {
        if (ch == '.') {
            if (section == 0) {
                maj = part;
                section = 1;
            } else if (section == 1) {
                min = part;
                section = 2;
            }
            part = 0;
        } else if (ch >= '0' and ch <= '9') {
            part = part * 10 + @as(u32, ch - '0');
        }
    }
    if (section == 0) {
        maj = part;
    } else if (section == 1) {
        min = part;
    } else {
        bld = part;
    }
    return .{ .major = maj, .minor = min, .build = bld };
}

fn versionString() []const u8 {
    if (config.isInitialized()) {
        return config.getVersion();
    }
    return "6.1.7601";
}

pub fn major() u32 {
    return parseVersionTriplet(versionString()).major;
}

pub fn minor() u32 {
    return parseVersionTriplet(versionString()).minor;
}

pub fn buildNumber() u32 {
    return parseVersionTriplet(versionString()).build;
}

pub fn platformId() u32 {
    return 2; // VER_PLATFORM_WIN32_NT
}

/// Narrow CSD line (e.g. "Service Pack 1") for GetVersionExA / ASCII paths.
pub fn csdVersionAscii() []const u8 {
    if (config.isInitialized()) {
        return config.getCsdVersion();
    }
    return "Service Pack 1";
}

pub fn servicePackMajor() u16 {
    const v = if (config.isInitialized())
        config.getServicePackMajor()
    else
        1;
    return @intCast(@min(v, 65535));
}

pub fn servicePackMinor() u16 {
    const v = if (config.isInitialized())
        config.getServicePackMinor()
    else
        0;
    return @intCast(@min(v, 65535));
}

pub fn suiteMask() u16 {
    const v = if (config.isInitialized())
        config.getSuiteMask()
    else
        0x0100;
    return @intCast(v & 0xFFFF);
}

/// VER_NT_WORKSTATION (1) for client SKUs.
pub fn productType() u8 {
    const v = if (config.isInitialized())
        config.getProductType()
    else
        1;
    return @intCast(@min(v, 255));
}

/// Binary size of `RTL_OSVERSIONINFOEXW` on Windows (no trailing padding beyond wReserved)。
/// 主机锚点：[tests/nt61_os_version_layout_host.zig](../../tests/nt61_os_version_layout_host.zig)。
pub const rtl_osversioninfoexw_bytes: u32 = 284;

/// Writes UTF-16LE fields for `RTL_OSVERSIONINFOEXW` into `buffer` (min 284 bytes).
pub fn writeRtlOsVersionInfoExW(buffer: []u8) bool {
    if (buffer.len < rtl_osversioninfoexw_bytes) return false;

    writeU32(buffer[0..4], rtl_osversioninfoexw_bytes);
    writeU32(buffer[4..8], major());
    writeU32(buffer[8..12], minor());
    writeU32(buffer[12..16], buildNumber());
    writeU32(buffer[16..20], platformId());

    var i: usize = 0;
    while (i < 128 * 2) : (i += 2) {
        writeU16(buffer[20 + i ..][0..2], 0);
    }
    const csd = csdVersionAscii();
    var pair: usize = 0;
    while (pair < 128) : (pair += 1) {
        const ch: u16 = if (pair < csd.len) csd[pair] else 0;
        writeU16(buffer[20 + pair * 2 ..][0..2], ch);
    }

    writeU16(buffer[276..278], servicePackMajor());
    writeU16(buffer[278..280], servicePackMinor());
    writeU16(buffer[280..282], suiteMask());
    buffer[282] = productType();
    buffer[283] = 0; // wReserved
    return true;
}

fn writeU32(buf: []u8, value: u32) void {
    buf[0] = @truncate(value & 0xFF);
    buf[1] = @truncate((value >> 8) & 0xFF);
    buf[2] = @truncate((value >> 16) & 0xFF);
    buf[3] = @truncate((value >> 24) & 0xFF);
}

fn writeU16(buf: []u8, value: u16) void {
    buf[0] = @truncate(value & 0xFF);
    buf[1] = @truncate((value >> 8) & 0xFF);
}

// ── RtlVerifyVersionInfo / VerSetConditionMask（公开头文件语义子集）──
// Ref: https://learn.microsoft.com/windows/win32/devnotes/rtlverifyversioninfo
// Ref: https://learn.microsoft.com/windows/win32/sysinfo/verifying-the-system-version

/// `type_mask` 位（与公开 `VER_*` 名称对应）。
pub const VER_MINORVERSION: u32 = 0x00000001;
pub const VER_MAJORVERSION: u32 = 0x00000002;
pub const VER_BUILDNUMBER: u32 = 0x00000004;
pub const VER_PLATFORMID: u32 = 0x00000008;
pub const VER_SERVICEPACKMAJOR: u32 = 0x00000020;
pub const VER_PRODUCT_TYPE: u32 = 0x00000080;

pub const VER_EQUAL: u8 = 1;
pub const VER_GREATER: u8 = 2;
pub const VER_GREATER_EQUAL: u8 = 3;
pub const VER_LESS: u8 = 4;
pub const VER_LESS_EQUAL: u8 = 5;

/// 与 `VerSetConditionMask` 等价的条件合并（每类 `type` 在 `condition_mask` 占 3 bit，索引为 `type` 标志的 bit 位）。
pub fn verSetConditionMask(initial_mask: u64, type_mask: u32, condition: u8) u64 {
    var m = initial_mask;
    var t = type_mask;
    while (t != 0) {
        const b: u32 = @ctz(t);
        const flag: u32 = @as(u32, 1) << @truncate(b);
        t ^= flag;
        const shift: u6 = @truncate(b * 3);
        m &= ~(@as(u64, 7) << shift);
        m |= @as(u64, condition & 7) << shift;
    }
    return m;
}

fn verGetCondition(condition_mask: u64, type_flag: u32) u8 {
    const b: u32 = @ctz(type_flag);
    const shift: u6 = @truncate(b * 3);
    return @truncate((condition_mask >> shift) & 7);
}

fn cmpCondU32(actual: u32, required: u32, cond: u8) bool {
    return switch (cond) {
        VER_EQUAL => actual == required,
        VER_GREATER => actual > required,
        VER_GREATER_EQUAL => actual >= required,
        VER_LESS => actual < required,
        VER_LESS_EQUAL => actual <= required,
        else => false,
    };
}

fn cmpCondU16(actual: u16, required: u16, cond: u8) bool {
    return switch (cond) {
        VER_EQUAL => actual == required,
        VER_GREATER => actual > required,
        VER_GREATER_EQUAL => actual >= required,
        VER_LESS => actual < required,
        VER_LESS_EQUAL => actual <= required,
        else => false,
    };
}

fn cmpCondU8(actual: u8, required: u8, cond: u8) bool {
    return switch (cond) {
        VER_EQUAL => actual == required,
        VER_GREATER => actual > required,
        VER_GREATER_EQUAL => actual >= required,
        VER_LESS => actual < required,
        VER_LESS_EQUAL => actual <= required,
        else => false,
    };
}

/// 将**当前** OS 版本（本模块单源）与调用方要求的字段比较；返回 `0`、`STATUS_NOT_EQUAL` 或 `STATUS_INVALID_PARAMETER`。
pub fn rtlVerifyVersionInfo(
    dw_major: u32,
    dw_minor: u32,
    dw_build: u32,
    dw_platform_id: u32,
    w_service_pack_major: u16,
    b_product_type: u8,
    type_mask: u32,
    condition_mask: u64,
) i32 {
    var tm = type_mask;
    while (tm != 0) {
        const b: u32 = @ctz(tm);
        const flag: u32 = @as(u32, 1) << @truncate(b);
        tm ^= flag;
        const cond = verGetCondition(condition_mask, flag);
        if (cond == 0 or cond > 5) return -1073741811; // STATUS_INVALID_PARAMETER

        const ok: bool = switch (flag) {
            VER_MINORVERSION => cmpCondU32(minor(), dw_minor, cond),
            VER_MAJORVERSION => cmpCondU32(major(), dw_major, cond),
            VER_BUILDNUMBER => cmpCondU32(buildNumber(), dw_build, cond),
            VER_PLATFORMID => cmpCondU32(platformId(), dw_platform_id, cond),
            VER_SERVICEPACKMAJOR => cmpCondU16(servicePackMajor(), w_service_pack_major, cond),
            VER_PRODUCT_TYPE => cmpCondU8(productType(), b_product_type, cond),
            else => false,
        };
        if (!ok) return @bitCast(@as(u32, 0xC0000159)); // STATUS_NOT_EQUAL
    }
    return 0;
}
