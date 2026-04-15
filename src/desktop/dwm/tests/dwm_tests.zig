// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM Tests

const std = @import("std");
const testing = std.testing;
const dwm = @import("dwm");

// ============================================================================
// Surface Manager Tests
// ============================================================================

test "SurfaceManager: create and destroy surface" {
    dwm.surface_mgr.initSurfaceManager();

    const surface_id = dwm.surface_mgr.createSurface(100, 100, .{ .has_alpha = true, .is_visible = true });
    try testing.expect(surface_id != dwm.surface_mgr.INVALID_SURFACE);
    try testing.expect(dwm.surface_mgr.getSurfaceCount() == 1);

    const destroyed = dwm.surface_mgr.destroySurface(surface_id);
    try testing.expect(destroyed);
    try testing.expect(dwm.surface_mgr.getSurfaceCount() == 0);
}

test "SurfaceManager: surface bounds" {
    dwm.surface_mgr.initSurfaceManager();

    const surface_id = dwm.surface_mgr.createSurface(640, 480, .{});
    const surface = dwm.surface_mgr.getSurface(surface_id);

    try testing.expect(surface != null);
    if (surface) |s| {
        try testing.expect(s.width == 640);
        try testing.expect(s.height == 480);
    }

    _ = dwm.surface_mgr.destroySurface(surface_id);
}

test "SurfaceManager: z-order sorting" {
    dwm.surface_mgr.initSurfaceManager();

    const s1 = dwm.surface_mgr.createSurface(100, 100, .{});
    const s2 = dwm.surface_mgr.createSurface(100, 100, .{});
    const s3 = dwm.surface_mgr.createSurface(100, 100, .{});

    dwm.surface_mgr.setSurfaceZOrder(s1, 10);
    dwm.surface_mgr.setSurfaceZOrder(s2, 5);
    dwm.surface_mgr.setSurfaceZOrder(s3, 15);

    dwm.surface_mgr.sortSurfacesByZOrder();

    _ = dwm.surface_mgr.destroySurface(s1);
    _ = dwm.surface_mgr.destroySurface(s2);
    _ = dwm.surface_mgr.destroySurface(s3);
}

// ============================================================================
// Compositor Tests
// ============================================================================

test "Compositor: initialization" {
    dwm.compositor.initCompositor(1920, 1080);
    try testing.expect(dwm.compositor.isDwmEnabled());

    const stats = dwm.compositor.getStats();
    try testing.expect(stats.total_frames == 0);
}

test "Compositor: surface management" {
    dwm.compositor.initCompositor(1920, 1080);

    const surface_id = dwm.surface_mgr.createSurface(400, 300, .{
        .has_alpha = true,
        .needs_shadow = true,
        .is_glass = true,
    });

    try testing.expect(surface_id != dwm.surface_mgr.INVALID_SURFACE);

    const surface = dwm.surface_mgr.getSurface(surface_id);
    try testing.expect(surface != null);
}

test "Compositor: hit test" {
    dwm.compositor.initCompositor(1920, 1080);

    const surface_id = dwm.surface_mgr.createSurface(100, 100, .{});
    dwm.surface_mgr.moveSurface(surface_id, 50, 50);

    const hit = dwm.surface_mgr.hitTestTopMost(75, 75);
    try testing.expect(hit != null);

    _ = dwm.surface_mgr.destroySurface(surface_id);
}

// ============================================================================
// Damage Tracking Tests
// ============================================================================

test "DamageTracker: rect operations" {
    const r1 = dwm.damage.DamageRect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const r2 = dwm.damage.DamageRect{ .x = 50, .y = 50, .w = 100, .h = 100 };

    const intersection = dwm.damage.rectIntersect(r1, r2);
    try testing.expect(intersection.x == 50);
    try testing.expect(intersection.y == 50);
    try testing.expect(intersection.w == 50);
    try testing.expect(intersection.h == 50);

    const union_rect = dwm.damage.unionRect(r1, r2);
    try testing.expect(union_rect.x == 0);
    try testing.expect(union_rect.y == 0);
    try testing.expect(union_rect.w == 150);
    try testing.expect(union_rect.h == 150);
}

// ============================================================================
// DWM API Tests
// ============================================================================

test "DWM API: composition state" {
    try testing.expect(dwm.dwmapi.isCompositionEnabled());
}

test "DWM API: thumbnail registration" {
    var thumb_id: dwm.dwmapi.HTHUMBNAIL = dwm.dwmapi.INVALID_THUMBNAIL;
    const result = dwm.dwmapi.DwmRegisterThumbnail(null, null, &thumb_id);

    try testing.expect(result == dwm.dwmapi.dwmapi_errors.S_OK or result == dwm.dwmapi.dwmapi_errors.E_INVALIDARG);

    if (thumb_id != dwm.dwmapi.INVALID_THUMBNAIL) {
        _ = dwm.dwmapi.DwmUnregisterThumbnail(thumb_id);
    }
}

// ============================================================================
// VSync Tests
// ============================================================================

test "VSync: state initialization" {
    dwm.vsync.initVSync();
    try testing.expect(dwm.vsync.g_vsync_state.enabled == true);
    try testing.expect(dwm.vsync.g_vsync_state.frame_target_us == 16667); // ~60 FPS
}

test "VSync: refresh rate calculation" {
    const hz = dwm.vsync.getRefreshIntervalHz(16667);
    try testing.expect(hz == 59 or hz == 60); // 1000000/16667 = 59.99 -> 59
}
