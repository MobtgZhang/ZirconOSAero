//! Shared desktop string gateway.
//! Gradually centralizes shell UI string access for both kernel desktop and aero host modules.

pub const shell_strings = @import("../kernel/strings/root.zig");
pub const shell_mui = @import("../kernel/strings/root.zig");

pub const LangId = shell_strings.LangId;

pub fn setActiveLang(id: LangId) void {
    shell_strings.setActiveLang(id);
}

pub fn startmenuLine(comptime field: []const u8) []const u8 {
    return shell_strings.startmenuLine(field);
}

pub fn explorerLine(comptime field: []const u8) []const u8 {
    return shell_strings.explorerLine(field);
}
