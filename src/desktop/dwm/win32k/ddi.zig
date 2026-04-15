// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DDI (Display Driver Interface)
//! Provides abstraction between the DWM and GPU drivers.

const std = @import("std");

// ============================================================================
// DDI Types
// ============================================================================

pub const DDI_VERSION = u32;
pub const DDI_VERSION_1: DDI_VERSION = 0x1000;
pub const DDI_VERSION_2: DDI_VERSION = 0x2000;

// ============================================================================
// Hardware Capabilities
// ============================================================================

pub const HardwareCaps = struct {
    max_texture_width: u32,
    max_texture_height: u32,
    max_render_targets: u32,
    supports_hw_vsync: bool,
    supports_blur: bool,
    supports_shadow: bool,
    supports_direct_rendering: bool,
    memory_total: usize,
    memory_available: usize,
};

// ============================================================================
// DDI Operations
// ============================================================================

pub const DDI_OPERATION = enum(u32) {
    create_surface = 1,
    destroy_surface = 2,
    present = 3,
    render = 4,
    sync = 5,
    allocate_memory = 6,
    free_memory = 7,
    flush = 8,
};

// ============================================================================
// DDI Result
// ============================================================================

pub const DDI_RESULT = enum(i32) {
    success = 0,
    @"error" = -1,
    out_of_memory = -2,
    invalid_parameters = -3,
    not_supported = -4,
    device_removed = -5,
};

// ============================================================================
// Surface Info
// ============================================================================

pub const DDISurfaceInfo = struct {
    width: u32,
    height: u32,
    format: u32,
    pitch: u32,
    handle: u64,
};

// ============================================================================
// DDI Interface
// ============================================================================

pub const DDIDriverInterface = struct {
    version: DDI_VERSION,
    caps: HardwareCaps,
    initialized: bool,

    pub fn init(self: *DDIDriverInterface) void {
        self.version = DDI_VERSION_1;
        self.caps = .{
            .max_texture_width = 4096,
            .max_texture_height = 4096,
            .max_render_targets = 8,
            .supports_hw_vsync = true,
            .supports_blur = true,
            .supports_shadow = true,
            .supports_direct_rendering = true,
            .memory_total = 256 * 1024 * 1024,
            .memory_available = 256 * 1024 * 1024,
        };
        self.initialized = true;
    }

    pub fn allocateSurface(self: *DDIDriverInterface, width: u32, height: u32, format: u32) ?DDISurfaceInfo {
        const size = width * height * 4;
        if (size > self.caps.memory_available) return null;

        self.caps.memory_available -= size;

        return .{
            .width = width,
            .height = height,
            .format = format,
            .pitch = width * 4,
            .handle = @as(u64, @intFromPtr(&self.caps)),
        };
    }

    pub fn freeSurface(self: *DDIDriverInterface, info: *const DDISurfaceInfo) void {
        const size = info.width * info.height * 4;
        self.caps.memory_available += size;
    }

    pub fn present(self: *DDIDriverInterface, surface: u64) DDI_RESULT {
        _ = surface;
        _ = self;
        return .success;
    }

    pub fn waitForVSync(self: *DDIDriverInterface) DDI_RESULT {
        _ = self;
        return .success;
    }

    pub fn flush(self: *DDIDriverInterface) DDI_RESULT {
        _ = self;
        return .success;
    }
};

// ============================================================================
// Global DDI Instance
// ============================================================================

pub var g_ddi_driver: DDIDriverInterface = .{};

pub fn initDDI() void {
    g_ddi_driver.init();
}

pub fn isDDIInitialized() bool {
    return g_ddi_driver.initialized;
}

pub fn getHardwareCaps() HardwareCaps {
    return g_ddi_driver.caps;
}

pub fn allocateDDISurface(width: u32, height: u32, format: u32) ?DDISurfaceInfo {
    return g_ddi_driver.allocateSurface(width, height, format);
}

pub fn freeDDISurface(info: *const DDISurfaceInfo) void {
    g_ddi_driver.freeSurface(info);
}

pub fn presentToDisplay(surface: u64) DDI_RESULT {
    return g_ddi_driver.present(surface);
}

pub fn waitForDisplayVSync() DDI_RESULT {
    return g_ddi_driver.waitForVSync();
}

pub fn flushDDI() DDI_RESULT {
    return g_ddi_driver.flush();
}
