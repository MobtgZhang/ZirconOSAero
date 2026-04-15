// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS WDDM Entry Point
//! Windows Display Driver Model implementation for ZirconOS.

const std = @import("std");

// Re-export WDDM modules
pub const vidmm = @import("vidmm.zig");
pub const cmd_buffer = @import("cmd_buffer.zig");
pub const fence = @import("fence.zig");
pub const scheduler = @import("scheduler.zig");

// ============================================================================
// Module State
// ============================================================================

pub var g_wddm_initialized: bool = false;

pub fn initWDDM() void {
    g_wddm_initialized = true;
}

pub fn deinitWDDM() void {
    g_wddm_initialized = false;
}

pub fn isWDDMInitialized() bool {
    return g_wddm_initialized;
}

// ============================================================================
// Version Info
// ============================================================================

pub const WDDMVersionInfo = struct {
    major: u32,
    minor: u32,
    name: []const u8,

    pub fn getVersion() WDDMVersionInfo {
        return .{
            .major = 1,
            .minor = 0,
            .name = "ZirconWDDM",
        };
    }
};
