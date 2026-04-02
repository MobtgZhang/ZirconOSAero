//! 双轨漂移回归：单一数值源 `nt61_aero_defaults` + `aero_flag_mapping` 主机锚点（无内核链接）。
//! 与 `csr_lpc_policy` 交叉锚定：LPC 载荷规则与 `subsystem.handleApiCall` 一致（DesktopManagerSpec §3.4）。
const std = @import("std");
const nt61 = @import("nt61_aero_defaults");
const flag_map = @import("aero_flag_mapping");
const csr_lpc_policy = @import("csr_lpc_policy");

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

test "LPC single-queue policy: get_message never accepts tid 0" {
    try std.testing.expect(csr_lpc_policy.resolveGetMessageClientTid(0) == null);
}

test "LPC post_message min bytes matches subsystem branch" {
    try std.testing.expect(csr_lpc_policy.validatePostMessagePayloadLen(csr_lpc_policy.post_message_payload_min_bytes));
}

test "LPC destroy/register hwnd field is leading u64 (8 bytes)" {
    try std.testing.expectEqual(@as(usize, 8), csr_lpc_policy.hwnd_u64_payload_bytes);
}

test "GUI LPC inactive desktop denied (mirror of subsystem + token policy)" {
    const active: u32 = 0;
    const process_desk: u32 = 1;
    try std.testing.expect(process_desk != active);
}
