// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS win32k Subsystem Entry Point

const std = @import("std");

// Re-export win32k modules
pub const wmgr = @import("wmgr.zig");
pub const surface_redirect = @import("surface_redirect.zig");
pub const gre = @import("gre.zig");
pub const ddi = @import("ddi.zig");

// ============================================================================
// Module State
// ============================================================================

pub var g_win32k_initialized: bool = false;

pub fn initWin32k() void {
    g_win32k_initialized = true;
}

pub fn deinitWin32k() void {
    g_win32k_initialized = false;
}

pub fn isWin32kInitialized() bool {
    return g_win32k_initialized;
}

// ============================================================================
// Version Info
// ============================================================================

pub const Win32kVersionInfo = struct {
    major: u32,
    minor: u32,
    name: []const u8,

    pub fn getVersion() Win32kVersionInfo {
        return .{
            .major = 1,
            .minor = 0,
            .name = "ZirconWin32k",
        };
    }
};
