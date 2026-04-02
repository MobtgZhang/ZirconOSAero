// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/config/aero_flag_mapping.zig
// Purpose: Documented mapping between kernel `KernelCompositorSurfaceFlags` and userland Aero `SurfaceFlags` (single semantic source).
//
// This is an independent clean-room implementation.
// Reference: https://learn.microsoft.com/windows/win32/learnwin32/the-desktop-window-manager
// Reference: docs/cn/DesktopManagerSpec.md, src/config/dwm_surface_spec.zig

const std = @import("std");
const dwm_surface_spec = @import("dwm_surface_spec.zig");

/// Re-export for tests / 桌面侧避免再挂一层 `dwm_surface_spec` 模块（Zig 15：同文件不可属多 module root）。
pub const KernelCompositorSurfaceFlags = dwm_surface_spec.KernelCompositorSurfaceFlags;

/// Mirrors **field names and order** of `src/desktop/aero/src/compositor.zig` `SurfaceFlags`.
/// `compositor.zig` calls `assertUserlandSurfaceFlagsLayout(SurfaceFlags)` so drift fails the desktop build.
pub const UserlandSurfaceFlagsLayout = struct {
    has_alpha: bool = false,
    needs_shadow: bool = false,
    is_visible: bool = true,
    is_opaque: bool = false,
    needs_blur: bool = false,
    is_glass: bool = false,
    is_cursor: bool = false,
    is_desktop: bool = false,
};

comptime {
    const nk = @typeInfo(dwm_surface_spec.KernelCompositorSurfaceFlags).@"struct".fields.len;
    const nu = @typeInfo(UserlandSurfaceFlagsLayout).@"struct".fields.len;
    if (nk != nu) @compileError("aero_flag_mapping: kernel vs userland SurfaceFlags field count drift");
}

comptime {
    const info = @typeInfo(UserlandSurfaceFlagsLayout).@"struct".fields;
    const expected: []const []const u8 = &.{
        "has_alpha",   "needs_shadow", "is_visible", "is_opaque",
        "needs_blur",  "is_glass",     "is_cursor",  "is_desktop",
    };
    if (info.len != expected.len) @compileError("UserlandSurfaceFlagsLayout: field count drift");
    for (info, expected) |fld, exp| {
        if (!std.mem.eql(u8, fld.name, exp))
            @compileError("UserlandSurfaceFlagsLayout: rename/order drift — sync compositor.zig + DesktopManagerSpec");
    }

    // 内核 ↔ 用户态语义锚点（变更 `kernelToUserland` 时必须同步文档与 DesktopManagerSpec）。
    const kb: dwm_surface_spec.KernelCompositorSurfaceFlags = .{ .dwm_blur_behind = true };
    const ub = kernelToUserland(kb);
    if (!(ub.needs_blur and ub.is_glass and !ub.is_opaque))
        @compileError("aero_flag_mapping: dwm_blur_behind must map to userland blur+glass and !opaque");

    const kl: dwm_surface_spec.KernelCompositorSurfaceFlags = .{ .layered = true };
    if (!kernelToUserland(kl).has_alpha)
        @compileError("aero_flag_mapping: layered must set userland has_alpha");

    const kp: dwm_surface_spec.KernelCompositorSurfaceFlags = .{ .popup = true };
    if (!kernelToUserland(kp).has_alpha)
        @compileError("aero_flag_mapping: popup must set userland has_alpha");

    const k0: dwm_surface_spec.KernelCompositorSurfaceFlags = .{};
    if (!kernelToUserland(k0).is_opaque)
        @compileError("aero_flag_mapping: default kernel surface maps to opaque userland (no layered/popup/blur)");

    // 逐内核标志「单 bit 为真」表驱动：防止只手搓 2～3 个样本时漏掉字段。
    const K = dwm_surface_spec.KernelCompositorSurfaceFlags;
    const k_fields = @typeInfo(K).@"struct".fields;
    for (k_fields) |fld| {
        var k1: K = .{};
        @field(k1, fld.name) = true;
        const mapped = kernelToUserland(k1);
        if (std.mem.eql(u8, fld.name, "layered") or std.mem.eql(u8, fld.name, "popup")) {
            if (!mapped.has_alpha) @compileError("aero_flag_mapping: layered/popup must set has_alpha");
        } else if (std.mem.eql(u8, fld.name, "dwm_blur_behind")) {
            if (!(mapped.needs_blur and mapped.is_glass and !mapped.is_opaque))
                @compileError("aero_flag_mapping: dwm_blur_behind single-flag invariant");
        } else if (std.mem.eql(u8, fld.name, "has_caption") or std.mem.eql(u8, fld.name, "child")) {
            if (!mapped.needs_shadow) @compileError("aero_flag_mapping: has_caption/child must set needs_shadow");
        } else if (std.mem.eql(u8, fld.name, "topmost")) {
            if (!mapped.is_opaque) @compileError("aero_flag_mapping: topmost alone must stay opaque userland");
        } else if (std.mem.eql(u8, fld.name, "snap_target")) {
            if (!mapped.is_opaque) @compileError("aero_flag_mapping: snap_target has no userland bit; must stay opaque");
        }
        // dwm_ncrendering：当前 kernelToUserland 不消费该项；单 true 与默认一致，无额外 userland 位。
    }
}

/// Map kernel compositor flags → userland logical model (Aero compositor).
/// Semantics: DesktopManagerSpec / MS Learn concepts — not a Windows code port.
pub fn kernelToUserland(kernel: dwm_surface_spec.KernelCompositorSurfaceFlags) UserlandSurfaceFlagsLayout {
    return .{
        .has_alpha = kernel.layered or kernel.popup,
        .needs_shadow = kernel.child or kernel.has_caption,
        .is_visible = true,
        .is_opaque = !(kernel.layered or kernel.dwm_blur_behind),
        .needs_blur = kernel.dwm_blur_behind,
        .is_glass = kernel.dwm_blur_behind,
        .is_cursor = false,
        .is_desktop = false,
    };
}

/// Best-effort inverse for tooling/tests (not all userland combinations are representable on kernel flags).
pub fn userlandToKernel(user: UserlandSurfaceFlagsLayout) dwm_surface_spec.KernelCompositorSurfaceFlags {
    return .{
        .topmost = false,
        .layered = user.has_alpha,
        .popup = false,
        .child = user.needs_shadow and !user.is_glass,
        .has_caption = user.needs_shadow,
        .dwm_blur_behind = user.needs_blur or user.is_glass,
        .dwm_ncrendering = true,
        .snap_target = false,
    };
}

pub fn assertUserlandSurfaceFlagsLayout(comptime Userland: type) void {
    const info = @typeInfo(Userland).@"struct".fields;
    const ref = @typeInfo(UserlandSurfaceFlagsLayout).@"struct".fields;
    if (info.len != ref.len) @compileError("SurfaceFlags field count != aero_flag_mapping.UserlandSurfaceFlagsLayout");
    inline for (info, ref) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name))
            @compileError("SurfaceFlags field name/order drift vs aero_flag_mapping");
    }
}

test "kernel blur maps to userland glass+blur" {
    const k: dwm_surface_spec.KernelCompositorSurfaceFlags = .{ .dwm_blur_behind = true };
    const u = kernelToUserland(k);
    try std.testing.expect(u.needs_blur);
    try std.testing.expect(u.is_glass);
    try std.testing.expect(!u.is_opaque);
}

test "userlandToKernel preserves blur_behind for glass" {
    const u = UserlandSurfaceFlagsLayout{ .is_glass = true, .needs_blur = true, .is_opaque = false };
    const k = userlandToKernel(u);
    try std.testing.expect(k.dwm_blur_behind);
}
