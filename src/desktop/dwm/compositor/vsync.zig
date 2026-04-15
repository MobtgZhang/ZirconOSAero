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

//! ZirconOS DWM Compositor - VSync Control

const std = @import("std");

// ============================================================================
// VSync State
// ============================================================================

pub const VsyncState = struct {
    enabled: bool = true,
    frame_target_us: u64 = 16667,
    last_present_tick: u64 = 0,
    frame_budget_remaining: i64 = 0,
    vsync_misses: u64 = 0,
};

// ============================================================================
// VSync Control
// ============================================================================

pub fn waitForVSync() void {
    // In a real implementation, this would wait for the display's vertical sync
    // For now, this is a placeholder that yields to other threads
    std.time.sleep(1 * std.time.ns_per_us);
}

pub fn shouldThrottleFrame(now_us: u64, state: *const VsyncState) bool {
    if (!state.enabled) return false;
    if (state.last_present_tick == 0) return false;
    return (now_us -| state.last_present_tick) < state.frame_target_us;
}

pub fn recordPresentTime(state: *VsyncState, now_us: u64) void {
    const elapsed: i64 = if (now_us > state.last_present_tick)
        @as(i64, @intCast(now_us - state.last_present_tick))
    else
        0;

    if (state.enabled and state.last_present_tick != 0 and elapsed > @as(i64, @intCast(state.frame_target_us))) {
        state.vsync_misses += 1;
    }
    state.last_present_tick = now_us;
}

pub fn getRefreshIntervalHz(frame_target_us: u64) u32 {
    if (frame_target_us == 0) return 60;
    return @as(u32, @intCast(1_000_000 / frame_target_us));
}

// ============================================================================
// Frame Timing
// ============================================================================

pub const FrameTiming = struct {
    frame_start: u64,
    compose_time: u64,
    present_time: u64,
    total_time: u64,
    dropped: bool,

    pub fn isOnTime(self: *const FrameTiming, budget_us: u64) bool {
        return self.total_time <= budget_us;
    }
};

// ============================================================================
// Adaptive VSync
// ============================================================================

pub const AdaptiveVSync = struct {
    enabled: bool,
    min_fps: u32,
    max_fps: u32,
    current_fps: u32,
    consecutive_low_fps: u32,
    consecutive_high_fps: u32,

    pub fn init(self: *AdaptiveVSync) void {
        self.enabled = true;
        self.min_fps = 30;
        self.max_fps = 144;
        self.current_fps = 60;
        self.consecutive_low_fps = 0;
        self.consecutive_high_fps = 0;
    }

    pub fn update(self: *AdaptiveVSync, actual_fps: u32) void {
        if (actual_fps < self.current_fps - 5) {
            self.consecutive_low_fps += 1;
            self.consecutive_high_fps = 0;
            if (self.consecutive_low_fps >= 10 and self.current_fps > self.min_fps) {
                self.current_fps = @max(self.current_fps - 1, self.min_fps);
                self.consecutive_low_fps = 0;
            }
        } else if (actual_fps > self.current_fps + 5) {
            self.consecutive_high_fps += 1;
            self.consecutive_low_fps = 0;
            if (self.consecutive_high_fps >= 30 and self.current_fps < self.max_fps) {
                self.current_fps = @min(self.current_fps + 1, self.max_fps);
                self.consecutive_high_fps = 0;
            }
        } else {
            self.consecutive_low_fps = 0;
            self.consecutive_high_fps = 0;
        }
    }

    pub fn getFrameInterval(self: *const AdaptiveVSync) u64 {
        if (self.current_fps == 0) return 16667;
        return 1_000_000 / @as(u64, self.current_fps);
    }
};

// ============================================================================
// Global VSync State
// ============================================================================

pub var g_vsync_state: VsyncState = .{};
pub var g_adaptive_vsync: AdaptiveVSync = .{
    .enabled = true,
    .min_fps = 30,
    .max_fps = 144,
    .current_fps = 60,
    .consecutive_low_fps = 0,
    .consecutive_high_fps = 0,
};

pub fn initVSync() void {
    g_vsync_state = .{ .enabled = true, .frame_target_us = 16667 };
    g_adaptive_vsync.init();
}

pub fn setVSyncEnabled(enabled: bool) void {
    g_vsync_state.enabled = enabled;
}

pub fn setRefreshRate(hz: u32) void {
    if (hz > 0) {
        g_vsync_state.frame_target_us = 1_000_000 / @as(u64, hz);
    }
}

pub fn shouldThrottle(now_us: u64) bool {
    return shouldThrottleFrame(now_us, &g_vsync_state);
}

pub fn recordPresent(now_us: u64) void {
    recordPresentTime(&g_vsync_state, now_us);
}
