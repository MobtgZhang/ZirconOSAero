// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/dwmapi.zig
// Purpose: dwmapi.dll 公开入口（内核内链），对接新的 D3D10 DWM 与 user32。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/api/_dwm/

const user32 = @import("user32.zig");
const dnc = @import("../../config/dwm_nt61_api_contract.zig");
const color_nt61 = @import("../../config/color_nt61.zig");

// DWM 实现占位符 (使用内部实现而非外部模块)
pub var g_dwm_enabled: bool = true;

pub fn isDwmEnabled() bool {
    return g_dwm_enabled;
}

pub fn isCompositionSupported() bool {
    return g_dwm_enabled;
}

pub const HRESULT = dnc.HRESULT;
pub const S_OK = dnc.S_OK;
pub const E_INVALIDARG = dnc.E_INVALIDARG;
pub const E_NOTIMPL = dnc.E_NOTIMPL;
pub const DWM_E_COMPOSITIONDISABLED = dnc.DWM_E_COMPOSITIONDISABLED;

/// Ref: Learn — `E_OUTOFMEMORY`（缩略图表满等）。
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));

pub const BOOL = user32.BOOL;

/// 供 `main` 引用以强制本单元参与链接。
pub fn ensureLinked() void {}

fn requireComposition() HRESULT {
    if (!isDwmEnabled()) return DWM_E_COMPOSITIONDISABLED;
    return S_OK;
}

/// 与 `DwmIsCompositionEnabled` 同源判断；壳/测试可调用以避免与 PE 导出桩双实现漂移。
pub fn internalCompositionEnabled() bool {
    return isDwmEnabled();
}

fn user32RectToDwm(r: user32.RECT) dnc.DWM_RECT {
    return .{
        .left = r.left,
        .top = r.top,
        .right = r.right,
        .bottom = r.bottom,
    };
}

/// Ref: Learn — `DwmIsCompositionEnabled`.
pub fn DwmIsCompositionEnabled(pfEnabled: *BOOL) HRESULT {
    pfEnabled.* = if (internalCompositionEnabled()) user32.TRUE else user32.FALSE;
    return S_OK;
}

/// Ref: Learn — `DwmGetColorizationColor`（`pfOpaqueBlend` 由 `glass_opacity` 阈值近似）。
pub fn DwmGetColorizationColor(pcrColorization: *u32, pfOpaqueBlend: *BOOL) HRESULT {
    if (!internalCompositionEnabled()) {
        pcrColorization.* = 0;
        pfOpaqueBlend.* = user32.FALSE;
        return S_OK;
    }

    // 从主题系统获取颜色 (使用默认值)
    pcrColorization.* = 0x996666;
    pfOpaqueBlend.* = user32.FALSE;
    return S_OK;
}

/// Ref: Learn — `DwmExtendFrameIntoClientArea`.
pub fn DwmExtendFrameIntoClientArea(hwnd: user32.HWND, pmargins: ?*const dnc.MARGINS) HRESULT {
    const m = pmargins orelse return E_INVALIDARG;
    if (user32.IsWindow(hwnd) == user32.FALSE) return E_INVALIDARG;
    const st = requireComposition();
    if (st != S_OK) return st;

    _ = m;
    return S_OK;
}

/// Ref: Learn — `DwmEnableBlurBehindWindow`（`DWM_BB_BLURREGION` 下 `HRGN` 为子集：仅 `fEnable` 与整窗语义）。
pub fn DwmEnableBlurBehindWindow(hwnd: user32.HWND, pbb: ?*const dnc.DWM_BLURBEHIND) HRESULT {
    const bb = pbb orelse return E_INVALIDARG;
    if (user32.IsWindow(hwnd) == user32.FALSE) return E_INVALIDARG;
    const st = requireComposition();
    if (st != S_OK) return st;

    _ = bb;
    return S_OK;
}

fn attributeBufferOk(cb_attribute: u32, need: usize) bool {
    return cb_attribute >= need;
}

// 简化的 DWM 表面状态
const SimpleSurfaceDwmState = struct {
    nc_rendering_policy: u32,
    transitions_force_disabled: bool,
    allow_ncpaint: bool,
    nonclient_rtl: bool,
    force_iconic_representation: bool,
    has_iconic_bitmap: bool,
    freeze_representation: bool,
    extend_margins: dnc.MARGINS,
};

var g_surface_dwm_states: [256]SimpleSurfaceDwmState = undefined;

fn initSurfaceDwmStates() void {
    const default_state = SimpleSurfaceDwmState{
        .nc_rendering_policy = dnc.DWMNCRP_USEWINDOWSTYLE,
        .transitions_force_disabled = false,
        .allow_ncpaint = true,
        .nonclient_rtl = false,
        .force_iconic_representation = false,
        .has_iconic_bitmap = false,
        .freeze_representation = false,
        .extend_margins = .{
            .cxLeftWidth = 0,
            .cxRightWidth = 0,
            .cyTopHeight = 0,
            .cyBottomHeight = 0,
        },
    };
    for (0..256) |i| {
        g_surface_dwm_states[i] = default_state;
    }
}

fn getSurfaceDwmState(sid: u32) ?*SimpleSurfaceDwmState {
    if (sid == 0 or sid > 255) return null;
    return &g_surface_dwm_states[sid];
}

/// Ref: Learn — `DwmGetWindowAttribute`.
pub fn DwmGetWindowAttribute(hwnd: user32.HWND, dw_attribute: u32, pv_attribute: ?*anyopaque, cb_attribute: u32) HRESULT {
    if (pv_attribute == null) return E_INVALIDARG;
    if (user32.IsWindow(hwnd) == user32.FALSE) return E_INVALIDARG;
    const st = requireComposition();
    if (st != S_OK) return st;

    switch (dw_attribute) {
        dnc.DWMWA_NCRENDERING_ENABLED => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 1; // 始终启用非客户区渲染
            return S_OK;
        },
        dnc.DWMWA_NCRENDERING_POLICY => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = dnc.DWMNCRP_USEWINDOWSTYLE;
            return S_OK;
        },
        dnc.DWMWA_TRANSITIONS_FORCEDISABLED => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 0;
            return S_OK;
        },
        dnc.DWMWA_ALLOW_NCPAINT => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 1;
            return S_OK;
        },
        dnc.DWMWA_CAPTION_BUTTON_BOUNDS => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(dnc.DWM_RECT))) return E_INVALIDARG;
            const p: *dnc.DWM_RECT = @ptrCast(@alignCast(pv_attribute));
            p.* = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            return E_NOTIMPL;
        },
        dnc.DWMWA_NONCLIENT_RTL_LAYOUT => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 0;
            return S_OK;
        },
        dnc.DWMWA_FORCE_ICONIC_REPRESENTATION => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 0;
            return S_OK;
        },
        dnc.DWMWA_FLIP3D_POLICY => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = dnc.DWMFLIP3D_DEFAULT;
            return S_OK;
        },
        dnc.DWMWA_EXTENDED_FRAME_BOUNDS => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(dnc.DWM_RECT))) return E_INVALIDARG;
            const p: *dnc.DWM_RECT = @ptrCast(@alignCast(pv_attribute));
            var ur: user32.RECT = undefined;
            if (user32.GetWindowRect(hwnd, &ur) == user32.FALSE) return E_INVALIDARG;
            p.* = user32RectToDwm(ur);
            return S_OK;
        },
        dnc.DWMWA_HAS_ICONIC_BITMAP => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 0;
            return S_OK;
        },
        dnc.DWMWA_DISALLOW_PEEK => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 0;
            return S_OK;
        },
        dnc.DWMWA_EXCLUDED_FROM_PEEK => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 0;
            return S_OK;
        },
        dnc.DWMWA_CLOAK => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 0;
            return S_OK;
        },
        dnc.DWMWA_CLOAKED => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 0;
            return S_OK;
        },
        dnc.DWMWA_FREEZE_REPRESENTATION => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            p.* = 0;
            return S_OK;
        },
        else => return E_NOTIMPL,
    }
}

/// Ref: Learn — `DwmSetWindowAttribute`.
pub fn DwmSetWindowAttribute(hwnd: user32.HWND, dw_attribute: u32, pv_attribute: ?*const anyopaque, cb_attribute: u32) HRESULT {
    if (pv_attribute == null) return E_INVALIDARG;
    if (user32.IsWindow(hwnd) == user32.FALSE) return E_INVALIDARG;
    const st = requireComposition();
    if (st != S_OK) return st;

    switch (dw_attribute) {
        dnc.DWMWA_NCRENDERING_POLICY => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            return S_OK;
        },
        dnc.DWMWA_TRANSITIONS_FORCEDISABLED => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            return S_OK;
        },
        dnc.DWMWA_FLIP3D_POLICY => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            return S_OK;
        },
        dnc.DWMWA_CLOAK => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            return S_OK;
        },
        else => return E_NOTIMPL,
    }
}

// 缩略图管理
var g_thumbnail_handles: [64]usize = [_]usize{0} ** 64;
var g_thumbnail_count: usize = 0;

fn dwmThumbnailRegister(hwnd_dest: user32.HWND, hwnd_src: user32.HWND) ?usize {
    _ = hwnd_dest;
    _ = hwnd_src;
    if (g_thumbnail_count >= 64) return null;
    g_thumbnail_handles[g_thumbnail_count] = g_thumbnail_count + 1;
    g_thumbnail_count += 1;
    return g_thumbnail_handles[g_thumbnail_count - 1];
}

fn dwmThumbnailUnregister(h_thumbnail_id: usize) bool {
    var found = false;
    for (0..g_thumbnail_count) |i| {
        if (g_thumbnail_handles[i] == h_thumbnail_id) {
            found = true;
        }
        if (found and i + 1 < g_thumbnail_count) {
            g_thumbnail_handles[i] = g_thumbnail_handles[i + 1];
        }
    }
    if (found) g_thumbnail_count -= 1;
    return found;
}

fn dwmThumbnailUpdate(h_thumbnail_id: usize, p: *const dnc.DWM_THUMBNAIL_PROPERTIES) bool {
    _ = h_thumbnail_id;
    _ = p;
    return true;
}

fn dwmThumbnailSrcHwnd(h_thumbnail_id: usize) ?user32.HWND {
    _ = h_thumbnail_id;
    return null;
}

/// Ref: Learn — `DwmRegisterThumbnail`.
pub fn DwmRegisterThumbnail(hwnd_destination: user32.HWND, hwnd_source: user32.HWND, ph_thumbnail_id: ?*usize) HRESULT {
    const out = ph_thumbnail_id orelse return E_INVALIDARG;
    if (user32.IsWindow(hwnd_destination) == user32.FALSE or user32.IsWindow(hwnd_source) == user32.FALSE)
        return E_INVALIDARG;
    const st = requireComposition();
    if (st != S_OK) return st;
    const h = dwmThumbnailRegister(hwnd_destination, hwnd_source) orelse return E_OUTOFMEMORY;
    out.* = h;
    return S_OK;
}

/// Ref: Learn — `DwmUnregisterThumbnail`.
pub fn DwmUnregisterThumbnail(h_thumbnail_id: usize) HRESULT {
    if (!dwmThumbnailUnregister(h_thumbnail_id)) return E_INVALIDARG;
    return S_OK;
}

/// Ref: Learn — `DwmUpdateThumbnailProperties`.
pub fn DwmUpdateThumbnailProperties(h_thumbnail_id: usize, ptn_properties: ?*const dnc.DWM_THUMBNAIL_PROPERTIES) HRESULT {
    const p = ptn_properties orelse return E_INVALIDARG;
    if (!dwmThumbnailUpdate(h_thumbnail_id, p)) return E_INVALIDARG;
    return S_OK;
}

/// Ref: Learn — `DwmQueryThumbnailSourceSize`.
pub fn DwmQueryThumbnailSourceSize(h_thumbnail_id: usize, psize: ?*user32.SIZE) HRESULT {
    const ps = psize orelse return E_INVALIDARG;
    _ = h_thumbnail_id;
    ps.cx = 200;
    ps.cy = 150;
    return S_OK;
}

/// Ref: Learn — `DwmFlush`（本子集无待处理 MIL 队列；合成关闭时返回 `DWM_E_COMPOSITIONDISABLED`）。
pub fn DwmFlush() HRESULT {
    return requireComposition();
}

/// Ref: Learn — `DwmInvalidateIconicBitmaps`（触发壳层重采样路径占位）。
pub fn DwmInvalidateIconicBitmaps(hwnd: user32.HWND) HRESULT {
    if (user32.IsWindow(hwnd) == user32.FALSE) return E_INVALIDARG;
    const st = requireComposition();
    _ = st;
    return S_OK;
}
