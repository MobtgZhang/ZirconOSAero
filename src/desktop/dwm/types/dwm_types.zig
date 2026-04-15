// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM Types

const std = @import("std");

// Re-export all types from submodules
pub const d3d10_types = @import("d3d10/d3d10_types.zig");
pub const d3d10_errors = @import("d3d10/d3d10_errors.zig");
pub const dxgi_types = @import("dxgi/dxgi_types.zig");
pub const dxgi_errors = @import("dxgi/dxgi_errors.zig");
pub const dwmapi_types = @import("dwmapi/dwmapi_types.zig");
pub const dwmapi_errors = @import("dwmapi/dwmapi_errors.zig");
pub const surface_mgr = @import("compositor/surface_mgr.zig");
pub const damage = @import("compositor/damage.zig");
pub const vsync = @import("compositor/vsync.zig");
pub const blur_shader = @import("shaders/blur_shader.zig");
pub const glass_shader = @import("shaders/glass_shader.zig");
pub const shadow_shader = @import("shaders/shadow_shader.zig");
