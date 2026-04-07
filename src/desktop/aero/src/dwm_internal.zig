//! 阶段 C：与 Microsoft Learn `Dwm*` 语义对齐的 **用户态 Zig API**（不经 PE 导出 thunk）。
//! 写入 [`compositor.zig`](compositor.zig) 的表面状态；内核内嵌 CSRSS 仍以 [`dwmapi.zig`](../../../subsystems/win32/dwmapi.zig) + `dwm_compositor` 为真源。

const std = @import("std");
const dnc = @import("dwm_nt61_api_contract");
const compositor = @import("compositor.zig");

pub const BOOL = i32;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

/// 对等 `DwmIsCompositionEnabled`（读用户态 compositor 开关）。
pub fn dwmInternalIsCompositionEnabled(pfEnabled: *BOOL) dnc.HRESULT {
    pfEnabled.* = if (compositor.isDwmEnabled()) TRUE else FALSE;
    return dnc.S_OK;
}

/// 对等 `DwmExtendFrameIntoClientArea`（`surface_id` 对应 compositor 表面 id）。
pub fn dwmInternalExtendFrameIntoClientArea(surface_id: u32, pmargins: ?*const dnc.MARGINS) dnc.HRESULT {
    const m = pmargins orelse return dnc.E_INVALIDARG;
    if (!compositor.isDwmEnabled()) return dnc.DWM_E_COMPOSITIONDISABLED;
    compositor.setSurfaceExtendMargins(surface_id, m.*);
    return dnc.S_OK;
}

/// 对等 `DwmEnableBlurBehindWindow`（`HRGN` 等标志为子集：见内核 `dwmapi.zig` 注释）。
pub fn dwmInternalEnableBlurBehindWindow(surface_id: u32, pbb: ?*const dnc.DWM_BLURBEHIND) dnc.HRESULT {
    const bb = pbb orelse return dnc.E_INVALIDARG;
    if (!compositor.isDwmEnabled()) return dnc.DWM_E_COMPOSITIONDISABLED;
    compositor.setSurfaceBlurBehindDwm(surface_id, bb.*);
    return dnc.S_OK;
}

test "dwmInternal extend margins round-trip on surface" {
    compositor.init(640, 480);
    const sid = compositor.createSurface(10, 10, .{ .is_visible = true });
    var enabled: BOOL = FALSE;
    try std.testing.expect(dwmInternalIsCompositionEnabled(&enabled) == dnc.S_OK);
    const m: dnc.MARGINS = .{
        .cxLeftWidth = 1,
        .cxRightWidth = 2,
        .cyTopHeight = 3,
        .cyBottomHeight = 4,
    };
    try std.testing.expect(dwmInternalExtendFrameIntoClientArea(sid, &m) == dnc.S_OK);
    const s = compositor.getSurface(sid).?;
    try std.testing.expectEqual(@as(i32, 1), s.extend_margins.cxLeftWidth);
    try std.testing.expectEqual(@as(i32, 4), s.extend_margins.cyBottomHeight);
}
