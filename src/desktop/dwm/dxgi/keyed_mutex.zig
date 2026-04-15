// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
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

//! DXGI Keyed Mutex Implementation for ZirconOS DWM
//! Clean-room implementation of IDXGIKeyedMutex interface.
//! Used for cross-process GPU synchronization between DWM and applications.

const std = @import("std");
pub const d3d10_types = @import("../d3d10/d3d10_types.zig");
pub const dxgi_errors = @import("dxgi_errors.zig");
const IDXGIDeviceSubObject = @import("dxgi.zig").IDXGIDeviceSubObject;

// ============================================================================
// IDXGIKeyedMutex Interface
// ============================================================================

pub const IDXGIKeyedMutex = extern struct {
    base: IDXGIDeviceSubObject,
    AcquireSync: fn (*const IDXGIKeyedMutex, u64, u32) callconv(.C) d3d10_types.HRESULT,
    ReleaseSync: fn (*const IDXGIKeyedMutex, u64) callconv(.C) d3d10_types.HRESULT,
};

// ============================================================================
// Keyed Mutex State
// ============================================================================

pub const KeyedMutexState = struct {
    ref_count: u32,
    current_key: u64,
    last_released_by: u32,
    is_acquired: bool,
    acquiring_process: u32,
};

pub const MAX_KEYED_MUTEXES: usize = 256;
pub var g_mutex_pool: [MAX_KEYED_MUTEXES]?KeyedMutexState = [_]?KeyedMutexState{null} ** MAX_KEYED_MUTEXES;
pub var g_mutex_count: usize = 0;

// ============================================================================
// AcquireSync
// ============================================================================

pub fn acquireSync(
    idx: usize,
    key: u64,
    timeout_ms: u32,
) d3d10_types.HRESULT {
    if (idx >= g_mutex_count or g_mutex_pool[idx] == null) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    const mtx = &g_mutex_pool[idx].?;

    if (mtx.is_acquired) {
        if (timeout_ms == 0) {
            return dxgi_errors.DXGI_ERROR_WAIT_TIMEOUT;
        }
        // In a real implementation, this would wait for the specified timeout
        // For now, we just return an error if already acquired
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    mtx.is_acquired = true;
    mtx.current_key = key;
    mtx.acquiring_process = std.os.windows.GetCurrentProcessId();

    return dxgi_errors.S_OK;
}

// ============================================================================
// ReleaseSync
// ============================================================================

pub fn releaseSync(
    idx: usize,
    key: u64,
) d3d10_types.HRESULT {
    if (idx >= g_mutex_count or g_mutex_pool[idx] == null) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    const mtx = &g_mutex_pool[idx].?;

    if (!mtx.is_acquired) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    // The key must match what was used in AcquireSync
    if (key != mtx.current_key) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    mtx.is_acquired = false;
    mtx.last_released_by = std.os.windows.GetCurrentProcessId();
    mtx.current_key = key + 1; // Increment key for next acquire

    return dxgi_errors.S_OK;
}

// ============================================================================
// Mutex Management
// ============================================================================

pub fn createKeyedMutex() !usize {
    if (g_mutex_count >= MAX_KEYED_MUTEXES) {
        return error.OutOfMemory;
    }

    g_mutex_pool[g_mutex_count] = .{
        .ref_count = 1,
        .current_key = 0,
        .last_released_by = 0,
        .is_acquired = false,
        .acquiring_process = 0,
    };

    const idx = g_mutex_count;
    g_mutex_count += 1;
    return idx;
}

pub fn isMutexAcquired(idx: usize) bool {
    if (idx < g_mutex_count and g_mutex_pool[idx] != null) {
        return g_mutex_pool[idx].?.is_acquired;
    }
    return false;
}

pub fn getCurrentKey(idx: usize) u64 {
    if (idx < g_mutex_count and g_mutex_pool[idx] != null) {
        return g_mutex_pool[idx].?.current_key;
    }
    return 0;
}

pub fn releaseMutex(idx: usize) void {
    if (idx < g_mutex_count and g_mutex_pool[idx] != null) {
        const mtx = &g_mutex_pool[idx].?;
        mtx.ref_count -= 1;
        if (mtx.ref_count == 0) {
            g_mutex_pool[idx] = null;
        }
    }
}

// ============================================================================
// DWM Sync Helper
// ============================================================================

/// Helper for DWM to sync with application surfaces
pub const DwmSyncHelper = struct {
    app_mutex_idx: usize,
    dwm_mutex_idx: usize,

    pub fn create() !DwmSyncHelper {
        return .{
            .app_mutex_idx = try createKeyedMutex(),
            .dwm_mutex_idx = try createKeyedMutex(),
        };
    }

    /// Acquire the surface for DWM reading (application has written)
    pub fn dwmAcquire(self: *DwmSyncHelper) d3d10_types.HRESULT {
        // First release from previous cycle
        _ = releaseSync(self.app_mutex_idx, self.getDwmKey());
        // Then acquire with new key
        return acquireSync(self.dwm_mutex_idx, self.getDwmKey(), 1000);
    }

    /// Release the surface back to application
    pub fn dwmRelease(self: *DwmSyncHelper) d3d10_types.HRESULT {
        return releaseSync(self.dwm_mutex_idx, self.getDwmKey());
    }

    fn getDwmKey(self: *DwmSyncHelper) u64 {
        // 0x44574D is ASCII for "DWM"
        return @as(u64, @as(u32, @intFromPtr(self))) | 0x44574D0000000000;
    }
};
