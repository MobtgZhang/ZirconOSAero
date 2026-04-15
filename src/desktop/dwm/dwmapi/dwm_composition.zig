// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// DWM Composition API Implementation

const std = @import("std");
pub const dwmapi_types = @import("dwmapi_types.zig");
pub const dwmapi_errors = @import("dwmapi_errors.zig");


// ============================================================================
// Composition State
// ============================================================================

pub var g_composition_enabled: bool = true;
pub var g_composition_supported: bool = true;

pub fn initComposition() void {
    g_composition_enabled = true;
    g_composition_supported = true;
}

pub fn isCompositionSupported() bool {
    return g_composition_supported;
}

// ============================================================================
// DwmEnable / DwmIsCompositionEnabled
// ============================================================================

pub fn DwmEnableComposition() dwmapi_types.HRESULT {
    if (!g_composition_supported) {
        return dwmapi_errors.DWM_E_NOTALLOWED;
    }
    g_composition_enabled = true;
    return dwmapi_errors.S_OK;
}

pub fn DwmDisableComposition() dwmapi_types.HRESULT {
    g_composition_enabled = false;
    return dwmapi_errors.S_OK;
}

pub fn DwmIsCompositionEnabled() dwmapi_types.HRESULT {
    if (g_composition_enabled and g_composition_supported) {
        return dwmapi_errors.S_OK;
    }
    return dwmapi_errors.S_FALSE;
}

pub fn isCompositionEnabled() bool {
    return g_composition_enabled and g_composition_supported;
}

// ============================================================================
// Composition Event Notifications
// ============================================================================

pub const CompositionCallback = *const fn (enabled: bool) void;

pub var g_composition_callback: ?CompositionCallback = null;

pub fn setCompositionCallback(callback: CompositionCallback) void {
    g_composition_callback = callback;
}

fn notifyCompositionChange(enabled: bool) void {
    if (g_composition_callback) |cb| {
        cb(enabled);
    }
}
