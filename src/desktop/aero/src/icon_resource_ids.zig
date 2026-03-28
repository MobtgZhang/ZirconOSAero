// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/aero/src/icon_resource_ids.zig
// Purpose: PE RT_ICON resource IDs (101–125) aligned with IconId 1–25 and win32/zircon_icon_ids.h.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.

const std = @import("std");

/// PE icon resource integer IDs for `zircon_shell32_res.dll` (host-built).
pub const PeIconId = enum(u16) {
    computer = 101,
    documents = 102,
    recycle_bin = 103,
    terminal = 104,
    network = 105,
    browser = 106,
    settings = 107,
    calculator = 108,
    text_editor = 109,
    pictures = 110,
    music = 111,
    folder = 112,
    control_panel = 113,
    file = 114,
    user = 115,
    lock = 116,
    shutdown = 117,
    recycle_bin_full = 118,
    drive_fixed = 119,
    drive_removable = 120,
    drive_optical = 121,
    printer = 122,
    info = 123,
    warning = 124,
    err = 125,
};

/// ICO / SVG basename under `resources/win32/ico/` (member `err` → file `error.ico`).
pub fn icoBasenameForPeId(id: PeIconId) []const u8 {
    return switch (id) {
        .computer => "computer",
        .documents => "documents",
        .recycle_bin => "recycle_bin",
        .terminal => "terminal",
        .network => "network",
        .browser => "browser",
        .settings => "settings",
        .calculator => "calculator",
        .text_editor => "text_editor",
        .pictures => "pictures",
        .music => "music",
        .folder => "folder",
        .control_panel => "control_panel",
        .file => "file",
        .user => "user",
        .lock => "lock",
        .shutdown => "shutdown",
        .recycle_bin_full => "recycle_bin_full",
        .drive_fixed => "drive_fixed",
        .drive_removable => "drive_removable",
        .drive_optical => "drive_optical",
        .printer => "printer",
        .info => "info",
        .warning => "warning",
        .err => "error",
    };
}

/// Maps logical shell `IconId` (1–25) to PE resource id when both enums use parallel ordering.
pub fn peIdForLogicalIcon(logical: u16) ?PeIconId {
    if (logical < 1 or logical > 25) return null;
    return @enumFromInt(@intFromEnum(PeIconId.computer) + (logical - 1));
}

test "icoBasenameForPeId maps err to error.ico stem" {
    try std.testing.expectEqualStrings("error", icoBasenameForPeId(.err));
    try std.testing.expectEqualStrings("computer", icoBasenameForPeId(.computer));
}

test "peIdForLogicalIcon maps IconId order to PE ids" {
    try std.testing.expectEqual(PeIconId.computer, peIdForLogicalIcon(1).?);
    try std.testing.expectEqual(PeIconId.printer, peIdForLogicalIcon(22).?);
    try std.testing.expectEqual(PeIconId.err, peIdForLogicalIcon(25).?);
    try std.testing.expect(peIdForLogicalIcon(0) == null);
    try std.testing.expect(peIdForLogicalIcon(26) == null);
}
