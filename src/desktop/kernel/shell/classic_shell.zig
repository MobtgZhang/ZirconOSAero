//! Windows 2000 classic shell data/model extracted from `core/display.zig`.

const shell_strings = @import("../strings/root.zig");

pub const W2kExLoc = enum { c_drive, c_winnt_system32, file_page };

pub const W2kSysRow = struct {
    name: []const u8,
    size: []const u8,
    kind: []const u8,
};

pub const w2k_path_system32 = "C:\\WINNT\\System32";

/// 仅含已编译的 NT 兼容二进制（示意），路径与 Windows 2000 一致（WINNT）。
pub const w2k_system32_entries = [_]W2kSysRow{
    .{ .name = "ntdll.dll", .size = "1,842 KB", .kind = "Application Extension" },
    .{ .name = "kernel32.dll", .size = "1,128 KB", .kind = "Application Extension" },
    .{ .name = "kernelbase.dll", .size = "2,312 KB", .kind = "Application Extension" },
    .{ .name = "user32.dll", .size = "1,028 KB", .kind = "Application Extension" },
    .{ .name = "gdi32.dll", .size = "412 KB", .kind = "Application Extension" },
    .{ .name = "advapi32.dll", .size = "688 KB", .kind = "Application Extension" },
    .{ .name = "shell32.dll", .size = "14,128 KB", .kind = "Application Extension" },
    .{ .name = "ole32.dll", .size = "1,408 KB", .kind = "Application Extension" },
    .{ .name = "comctl32.dll", .size = "612 KB", .kind = "Application Extension" },
    .{ .name = "shlwapi.dll", .size = "456 KB", .kind = "Application Extension" },
    .{ .name = "explorer.exe", .size = "412 KB", .kind = "Application" },
    .{ .name = "winlogon.exe", .size = "532 KB", .kind = "Application" },
    .{ .name = "csrss.exe", .size = "6 KB", .kind = "Application" },
    .{ .name = "services.exe", .size = "108 KB", .kind = "Application" },
    .{ .name = "lsass.exe", .size = "32 KB", .kind = "Application" },
};

pub fn explorerW2kWindowTitle(loc: W2kExLoc, file_page_name: []const u8) []const u8 {
    return switch (loc) {
        .c_drive => shell_strings.en.w2k_title_c_drive,
        .c_winnt_system32 => w2k_path_system32,
        .file_page => file_page_name,
    };
}
