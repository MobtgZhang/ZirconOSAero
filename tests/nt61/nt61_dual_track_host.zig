//! 双轨漂移回归：单一数值源 `nt61_aero_defaults` + `aero_flag_mapping` 主机锚点（无内核链接）。
const std = @import("std");
const nt61 = @import("nt61_aero_defaults");
const flag_map = @import("aero_flag_mapping");

test "compositor_config_epoch discipline (bump when kernel/shell defaults change together)" {
    try std.testing.expect(nt61.compositor_config_epoch >= 4);
}

test "UserShellDwm glass_tint mirrors KernelDwm (runtime smoke; comptime locks in nt61_aero_defaults.zig)" {
    try std.testing.expectEqual(nt61.KernelDwm.glass_tint_color, nt61.UserShellDwm.glass_tint_color);
}

test "kernel blur flag maps to userland glass+blur" {
    const k: flag_map.KernelCompositorSurfaceFlags = .{ .dwm_blur_behind = true };
    const u = flag_map.kernelToUserland(k);
    try std.testing.expect(u.needs_blur and u.is_glass and !u.is_opaque);
}

test "userlandToKernel round-trip preserves dwm_blur_behind for glass surface" {
    const u = flag_map.UserlandSurfaceFlagsLayout{
        .has_alpha = true,
        .needs_shadow = true,
        .is_visible = true,
        .is_opaque = false,
        .needs_blur = true,
        .is_glass = true,
        .is_cursor = false,
        .is_desktop = false,
    };
    const k = flag_map.userlandToKernel(u);
    try std.testing.expect(k.dwm_blur_behind);
}
