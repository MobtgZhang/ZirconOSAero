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
