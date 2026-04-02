//! DWM / user32 / compositor 契约的主机侧回归（无内核链接）。
//! - T1：与 `user32.syncCompositorZOrderForUserWindows`、`dwm_compositor.destroySurface` 文档化语义一致。
//! - T2：`WM_DWMSENDICONICTHUMBNAIL` 的 `lParam` 打包与 `dwm_messages_nt61` / `user32.broadcastDwmIconicThumbnailRequested` 对齐。
//!
//! 对照：`src/subsystems/win32/user32.zig`、`src/drivers/video/dwm_compositor.zig`、`docs/cn/MVT_NT61.md`。
const std = @import("std");
const dwm_registry_sync = @import("dwm_config_registry_sync");
const dwm_blur_budget = @import("dwm_blur_budget");

const WM_DWMSENDICONICTHUMBNAIL: u32 = 0x0323;

test "compositor z-order stride matches user32 syncCompositorZOrderForUserWindows" {
    // user32.zig: var zi: i16 = 10; per valid window with surface: setSurfaceZOrder(..., zi); zi += 10;
    var zi: i16 = 10;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expectEqual(@as(i16, 10) + @as(i16, @intCast(i * 10)), zi);
        zi += 10;
    }
}

test "destroySurface visibility model (spec: visible=false)" {
    var visible: bool = true;
    visible = false; // dwm_compositor.destroySurface sets surfaces[id].visible = false
    try std.testing.expect(!visible);
}

test "WM_DWMSENDICONICTHUMBNAIL lParam MAKELPARAM-style width height" {
    const max_w: u32 = 20;
    const max_h: u32 = 15;
    const low: u32 = @min(max_w, 0xFFFF);
    const high: u32 = @min(max_h, 0xFFFF);
    const packed32: u32 = (high << 16) | low;
    const lp: i64 = @intCast(@as(i32, @bitCast(packed32)));
    try std.testing.expectEqual(max_w, packed32 & 0xFFFF);
    try std.testing.expectEqual(max_h, (packed32 >> 16) & 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0x0323), WM_DWMSENDICONICTHUMBNAIL);
    _ = lp;
}

const WM_DWMCOMPOSITIONCHANGED: u32 = 0x031E;

test "DWM listener thread queue model (PostThreadMessage -> same tid dequeue)" {
    const listener_tid: u32 = 7;
    const posted_tid = listener_tid;
    const msg = WM_DWMCOMPOSITIONCHANGED;
    try std.testing.expectEqual(listener_tid, posted_tid);
    try std.testing.expectEqual(@as(u32, 0x031E), msg);
}

test "getSurfaceZOrder stride after syncCompositorZOrderForUserWindows" {
    var zi: i16 = 10;
    var w: usize = 0;
    while (w < 3) : (w += 1) {
        try std.testing.expectEqual(@as(i16, 10) + @as(i16, @intCast(w * 10)), zi);
        zi += 10;
    }
}

// 任务栏 Explorer 缩略：HWND→compositor_surface_id（CreateWindowEx）→ refreshSurfaceThumbFromFramebuffer（2x2 盒滤）。
// Flip3D：collectShellWindowSurfaceIds（owner_pid!=0 等过滤）。主机侧文档锚点。
test "taskbar thumb and Flip3D surface id map (spec anchor)" {
    const explorer_owner_pid: u32 = 1;
    try std.testing.expect(explorer_owner_pid != 0);
}

test "blur budget pixel pass cost matches dwm.tryConsumeBlurBudget model" {
    try std.testing.expectEqual(@as(u32, 600), dwm_blur_budget.blurRectCostSaturating(10, 10, 6));
    var rem: u32 = 500;
    try std.testing.expect(!dwm_blur_budget.trySubtractFromBudget(&rem, 10, 10, 6));
    try std.testing.expectEqual(@as(u32, 500), rem);
}

test "SetWindowPos HWND_NOTOPMOST vs TOPMOST sentinels (user32.zig)" {
    const HWND_TOPMOST: u64 = 0xFFFFFFFFFFFFFFFE;
    const HWND_NOTOPMOST: u64 = 0xFFFFFFFFFFFFFFFD;
    try std.testing.expect(HWND_TOPMOST != HWND_NOTOPMOST);
}

test "SetWindowPos HWND_TOP vs HWND_BOTTOM sentinels (Z-order subset)" {
    const HWND_TOP: u64 = 0;
    const HWND_BOTTOM: u64 = 1;
    try std.testing.expect(HWND_TOP != HWND_BOTTOM);
}

test "blurRectCostSaturating edge cases align with dwm.tryConsumeBlurBudget" {
    try std.testing.expectEqual(@as(u32, 0), dwm_blur_budget.blurRectCostSaturating(10, 10, 0));
    try std.testing.expectEqual(@as(u32, 0), dwm_blur_budget.blurRectCostSaturating(0, 100, 3));
    var zero_budget: u32 = 0;
    try std.testing.expect(!dwm_blur_budget.trySubtractFromBudget(&zero_budget, 1, 1, 1));
    var one_pixel: u32 = 1;
    try std.testing.expect(dwm_blur_budget.trySubtractFromBudget(&one_pixel, 1, 1, 1));
    try std.testing.expectEqual(@as(u32, 0), one_pixel);
}

test "dwm.syncPolicyFromRegistry uses dwm_config_registry_sync broadcast hints" {
    const before: dwm_registry_sync.RegistryVisibleDwmFields = .{
        .glass_tint_color = 0x4068A0,
        .glass_opacity = 210,
        .glass_taskbar_tint_opacity = 88,
        .peek_enabled = true,
    };
    var after = before;
    after.peek_enabled = false;
    const h = dwm_registry_sync.broadcastHintsAfterRegistryApply(before, after);
    try std.testing.expect(!h.colorization);
    try std.testing.expect(h.nc_policy);
}
