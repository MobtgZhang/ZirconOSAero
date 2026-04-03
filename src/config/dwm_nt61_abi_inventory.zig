// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/config/dwm_nt61_abi_inventory.zig
// Purpose: Single-source list of NT 6.1 dwmapi exports (names + test anchors) for PE / ABI parity; clean-room from Microsoft Learn only.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/api/_dwm/

const std = @import("std");

/// One public `dwmapi.dll` entry (Win Vista/7 documented surface used by this kernel).
pub const DwmApiExport = struct {
    /// PE export name (undecorated).
    name: []const u8,
    /// Host regression anchor (`zig build test`); keep stable when adding tests.
    test_anchor: []const u8,
    /// `HRESULT` vs `BOOL` return convention per Learn.
    returns: enum { hresult, bool_only },
};

/// Order matches synthetic ordinals in [`pe.zig`](../../loader/pe.zig) `initSystemDlls` for `dwmapi.dll` (1..12).
pub const dwmapi_exports_nt61: []const DwmApiExport = &.{
    .{ .name = "DwmIsCompositionEnabled", .test_anchor = "dwm_nt61_api_contract_host", .returns = .bool_only },
    .{ .name = "DwmGetColorizationColor", .test_anchor = "dwm_nt61_api_contract_host", .returns = .hresult },
    .{ .name = "DwmExtendFrameIntoClientArea", .test_anchor = "dwm_nt61_integration_host", .returns = .hresult },
    .{ .name = "DwmEnableBlurBehindWindow", .test_anchor = "dwm_nt61_api_contract_host", .returns = .hresult },
    .{ .name = "DwmGetWindowAttribute", .test_anchor = "dwm_nt61_integration_host", .returns = .hresult },
    .{ .name = "DwmSetWindowAttribute", .test_anchor = "dwm_nt61_integration_host", .returns = .hresult },
    .{ .name = "DwmRegisterThumbnail", .test_anchor = "dwm_nt61_integration_host", .returns = .hresult },
    .{ .name = "DwmUnregisterThumbnail", .test_anchor = "dwm_nt61_integration_host", .returns = .hresult },
    .{ .name = "DwmUpdateThumbnailProperties", .test_anchor = "dwm_nt61_api_contract_host", .returns = .hresult },
    .{ .name = "DwmQueryThumbnailSourceSize", .test_anchor = "dwm_nt61_integration_host", .returns = .hresult },
    .{ .name = "DwmFlush", .test_anchor = "dwm_nt61_integration_host", .returns = .hresult },
    .{ .name = "DwmInvalidateIconicBitmaps", .test_anchor = "dwm_messages_nt61_host", .returns = .hresult },
};

/// user32 symbols touched by phase-4 DWM integration (documentation parity; not full user32 export table).
pub const user32_dwm_related: []const []const u8 = &.{
    "PostThreadMessageA",
    "GetMessage",
    "PeekMessage",
    "CreateWindowExA",
    "DestroyWindow",
    "SetWindowPos",
};

comptime {
    std.debug.assert(dwmapi_exports_nt61.len == 12);
}

test "dwmapi export inventory count matches PE synthetic dwmapi.dll" {
    try std.testing.expectEqual(@as(usize, 12), dwmapi_exports_nt61.len);
    try std.testing.expectEqualStrings("DwmIsCompositionEnabled", dwmapi_exports_nt61[0].name);
    try std.testing.expectEqualStrings("DwmInvalidateIconicBitmaps", dwmapi_exports_nt61[11].name);
}
