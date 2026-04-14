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
// Purpose: dwmapi.dll 公开入口（内核内链），对接 `dwm_compositor` 与 `user32`。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/api/_dwm/

const user32 = @import("user32.zig");
const video_root = @import("../../drivers/video/root.zig");
const dwm = video_root.dwm;
const dwm_comp = video_root.dwm_compositor;
const dnc = @import("../../config/dwm_nt61_api_contract.zig");
const color_nt61 = @import("../../config/color_nt61.zig");

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
    if (!dwm.isInitialized() or !dwm.isEnabled()) return DWM_E_COMPOSITIONDISABLED;
    return S_OK;
}

/// 与 `DwmIsCompositionEnabled` 同源判断；壳/测试可调用以避免与 PE 导出桩双实现漂移。
pub fn internalCompositionEnabled() bool {
    return dwm.isInitialized() and dwm.isEnabled();
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
    if (!dwm.isInitialized()) {
        pcrColorization.* = 0;
        pfOpaqueBlend.* = user32.FALSE;
        return S_OK;
    }
    const cfg = dwm.getConfig();
    pcrColorization.* = color_nt61.colorrefLow24FromKernelBgr24(cfg.glass_tint_color);
    pfOpaqueBlend.* = if (cfg.glass_opacity >= 128) user32.TRUE else user32.FALSE;
    return S_OK;
}

/// Ref: Learn — `DwmExtendFrameIntoClientArea`.
pub fn DwmExtendFrameIntoClientArea(hwnd: user32.HWND, pmargins: ?*const dnc.MARGINS) HRESULT {
    const m = pmargins orelse return E_INVALIDARG;
    if (user32.IsWindow(hwnd) == user32.FALSE) return E_INVALIDARG;
    const st = requireComposition();
    if (st != S_OK) return st;
    const sid = user32.tryGetCompositorSurfaceId(hwnd) orelse return S_OK;
    dwm_comp.setSurfaceExtendMargins(sid, m.*);
    return S_OK;
}

/// Ref: Learn — `DwmEnableBlurBehindWindow`（`DWM_BB_BLURREGION` 下 `HRGN` 为子集：仅 `fEnable` 与整窗语义）。
pub fn DwmEnableBlurBehindWindow(hwnd: user32.HWND, pbb: ?*const dnc.DWM_BLURBEHIND) HRESULT {
    const bb = pbb orelse return E_INVALIDARG;
    if (user32.IsWindow(hwnd) == user32.FALSE) return E_INVALIDARG;
    const st = requireComposition();
    if (st != S_OK) return st;
    const sid = user32.tryGetCompositorSurfaceId(hwnd) orelse return S_OK;
    dwm_comp.setSurfaceBlurBehind(sid, bb.*);
    return S_OK;
}

fn attributeBufferOk(cb_attribute: u32, need: usize) bool {
    return cb_attribute >= need;
}

/// Ref: Learn — `DwmGetWindowAttribute`.
pub fn DwmGetWindowAttribute(hwnd: user32.HWND, dw_attribute: u32, pv_attribute: ?*anyopaque, cb_attribute: u32) HRESULT {
    if (pv_attribute == null) return E_INVALIDARG;
    if (user32.IsWindow(hwnd) == user32.FALSE) return E_INVALIDARG;
    const st = requireComposition();
    if (st != S_OK) return st;

    const sid_opt = user32.tryGetCompositorSurfaceId(hwnd);

    switch (dw_attribute) {
        dnc.DWMWA_NCRENDERING_ENABLED => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                const s = dwm_comp.getSurfaceDwmState(sid) orelse {
                    p.* = 0;
                    return S_OK;
                };
                p.* = if (s.nc_rendering_policy != dnc.DWMNCRP_DISABLED) 1 else 0;
            } else {
                p.* = 1;
            }
            return S_OK;
        },
        dnc.DWMWA_NCRENDERING_POLICY => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                const s = dwm_comp.getSurfaceDwmState(sid) orelse {
                    p.* = dnc.DWMNCRP_USEWINDOWSTYLE;
                    return S_OK;
                };
                p.* = s.nc_rendering_policy;
            } else {
                p.* = dnc.DWMNCRP_USEWINDOWSTYLE;
            }
            return S_OK;
        },
        dnc.DWMWA_TRANSITIONS_FORCEDISABLED => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                const s = dwm_comp.getSurfaceDwmState(sid) orelse {
                    p.* = 0;
                    return S_OK;
                };
                p.* = if (s.transitions_force_disabled) 1 else 0;
            } else {
                p.* = 0;
            }
            return S_OK;
        },
        dnc.DWMWA_ALLOW_NCPAINT => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                const s = dwm_comp.getSurfaceDwmState(sid) orelse {
                    p.* = 1;
                    return S_OK;
                };
                p.* = if (s.allow_ncpaint) 1 else 0;
            } else {
                p.* = 1;
            }
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
            if (sid_opt) |sid| {
                const s = dwm_comp.getSurfaceDwmState(sid) orelse {
                    p.* = 0;
                    return S_OK;
                };
                p.* = if (s.nonclient_rtl) 1 else 0;
            } else {
                p.* = 0;
            }
            return S_OK;
        },
        dnc.DWMWA_FORCE_ICONIC_REPRESENTATION => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                const s = dwm_comp.getSurfaceDwmState(sid) orelse {
                    p.* = 0;
                    return S_OK;
                };
                p.* = if (s.force_iconic_representation) 1 else 0;
            } else {
                p.* = 0;
            }
            return S_OK;
        },
        dnc.DWMWA_FLIP3D_POLICY => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                p.* = dwm_comp.getSurfaceFlip3dPolicy(sid);
            } else {
                p.* = dnc.DWMFLIP3D_DEFAULT;
            }
            return S_OK;
        },
        dnc.DWMWA_EXTENDED_FRAME_BOUNDS => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(dnc.DWM_RECT))) return E_INVALIDARG;
            const p: *dnc.DWM_RECT = @ptrCast(@alignCast(pv_attribute));
            var ur: user32.RECT = undefined;
            if (user32.GetWindowRect(hwnd, &ur) == user32.FALSE) return E_INVALIDARG;
            if (sid_opt) |sid| {
                if (dwm_comp.getSurfaceDwmState(sid)) |s| {
                    const m = s.extend_margins;
                    p.* = .{
                        .left = ur.left - m.cxLeftWidth,
                        .top = ur.top - m.cyTopHeight,
                        .right = ur.right + m.cxRightWidth,
                        .bottom = ur.bottom + m.cyBottomHeight,
                    };
                    return S_OK;
                }
            }
            p.* = user32RectToDwm(ur);
            return S_OK;
        },
        dnc.DWMWA_HAS_ICONIC_BITMAP => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                const s = dwm_comp.getSurfaceDwmState(sid) orelse {
                    p.* = 0;
                    return S_OK;
                };
                p.* = if (s.has_iconic_bitmap) 1 else 0;
            } else {
                p.* = 0;
            }
            return S_OK;
        },
        dnc.DWMWA_DISALLOW_PEEK => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                p.* = if (dwm_comp.surfaceDisallowsPeek(sid)) 1 else 0;
            } else {
                p.* = 0;
            }
            return S_OK;
        },
        dnc.DWMWA_EXCLUDED_FROM_PEEK => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                p.* = if (dwm_comp.surfaceExcludedFromPeek(sid)) 1 else 0;
            } else {
                p.* = 0;
            }
            return S_OK;
        },
        dnc.DWMWA_CLOAK => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                p.* = if (dwm_comp.surfaceIsCloaked(sid)) 1 else 0;
            } else {
                p.* = 0;
            }
            return S_OK;
        },
        dnc.DWMWA_CLOAKED => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                p.* = if (dwm_comp.surfaceIsCloaked(sid)) 1 else 0;
            } else {
                p.* = 0;
            }
            return S_OK;
        },
        dnc.DWMWA_FREEZE_REPRESENTATION => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *u32 = @ptrCast(@alignCast(pv_attribute));
            if (sid_opt) |sid| {
                const s = dwm_comp.getSurfaceDwmState(sid) orelse {
                    p.* = 0;
                    return S_OK;
                };
                p.* = if (s.freeze_representation) 1 else 0;
            } else {
                p.* = 0;
            }
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
    const sid = user32.tryGetCompositorSurfaceId(hwnd) orelse return S_OK;

    switch (dw_attribute) {
        dnc.DWMWA_NCRENDERING_POLICY => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *const u32 = @ptrCast(@alignCast(pv_attribute));
            dwm_comp.setSurfaceNcRenderingPolicy(sid, p.*);
            return S_OK;
        },
        dnc.DWMWA_TRANSITIONS_FORCEDISABLED => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *const u32 = @ptrCast(@alignCast(pv_attribute));
            // Unsafe: documented as BOOL; treat non-zero as true.
            dwm_comp.surfaceDwmSetTransitionsForceDisabled(sid, p.* != 0);
            return S_OK;
        },
        dnc.DWMWA_ALLOW_NCPAINT => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *const u32 = @ptrCast(@alignCast(pv_attribute));
            dwm_comp.surfaceDwmSetAllowNcPaint(sid, p.* != 0);
            return S_OK;
        },
        dnc.DWMWA_NONCLIENT_RTL_LAYOUT => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *const u32 = @ptrCast(@alignCast(pv_attribute));
            dwm_comp.surfaceDwmSetNonClientRtl(sid, p.* != 0);
            return S_OK;
        },
        dnc.DWMWA_FORCE_ICONIC_REPRESENTATION => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *const u32 = @ptrCast(@alignCast(pv_attribute));
            dwm_comp.surfaceDwmSetForceIconic(sid, p.* != 0);
            return S_OK;
        },
        dnc.DWMWA_FLIP3D_POLICY => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *const u32 = @ptrCast(@alignCast(pv_attribute));
            dwm_comp.setSurfaceFlip3dPolicy(sid, p.*);
            return S_OK;
        },
        dnc.DWMWA_DISALLOW_PEEK => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *const u32 = @ptrCast(@alignCast(pv_attribute));
            dwm_comp.setSurfacePeekFlags(sid, p.* != 0, dwm_comp.surfaceExcludedFromPeek(sid));
            return S_OK;
        },
        dnc.DWMWA_EXCLUDED_FROM_PEEK => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *const u32 = @ptrCast(@alignCast(pv_attribute));
            dwm_comp.setSurfacePeekFlags(sid, dwm_comp.surfaceDisallowsPeek(sid), p.* != 0);
            return S_OK;
        },
        dnc.DWMWA_CLOAK => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *const u32 = @ptrCast(@alignCast(pv_attribute));
            dwm_comp.setSurfaceCloak(sid, p.* != 0);
            return S_OK;
        },
        dnc.DWMWA_FREEZE_REPRESENTATION => {
            if (!attributeBufferOk(cb_attribute, @sizeOf(u32))) return E_INVALIDARG;
            const p: *const u32 = @ptrCast(@alignCast(pv_attribute));
            dwm_comp.surfaceDwmSetFreezeRepresentation(sid, p.* != 0);
            return S_OK;
        },
        dnc.DWMWA_EXTENDED_FRAME_BOUNDS, dnc.DWMWA_CAPTION_BUTTON_BOUNDS, dnc.DWMWA_NCRENDERING_ENABLED, dnc.DWMWA_HAS_ICONIC_BITMAP, dnc.DWMWA_CLOAKED => return E_INVALIDARG,
        else => return E_NOTIMPL,
    }
}

/// Ref: Learn — `DwmRegisterThumbnail`.
pub fn DwmRegisterThumbnail(hwnd_destination: user32.HWND, hwnd_source: user32.HWND, ph_thumbnail_id: ?*usize) HRESULT {
    const out = ph_thumbnail_id orelse return E_INVALIDARG;
    if (user32.IsWindow(hwnd_destination) == user32.FALSE or user32.IsWindow(hwnd_source) == user32.FALSE)
        return E_INVALIDARG;
    const st = requireComposition();
    if (st != S_OK) return st;
    const h = dwm_comp.dwmThumbnailRegister(hwnd_destination, hwnd_source) orelse return E_OUTOFMEMORY;
    out.* = h;
    return S_OK;
}

/// Ref: Learn — `DwmUnregisterThumbnail`.
pub fn DwmUnregisterThumbnail(h_thumbnail_id: usize) HRESULT {
    if (!dwm_comp.dwmThumbnailUnregister(h_thumbnail_id)) return E_INVALIDARG;
    return S_OK;
}

/// Ref: Learn — `DwmUpdateThumbnailProperties`.
pub fn DwmUpdateThumbnailProperties(h_thumbnail_id: usize, ptn_properties: ?*const dnc.DWM_THUMBNAIL_PROPERTIES) HRESULT {
    const p = ptn_properties orelse return E_INVALIDARG;
    if (!dwm_comp.dwmThumbnailUpdate(h_thumbnail_id, p)) return E_INVALIDARG;
    return S_OK;
}

/// Ref: Learn — `DwmQueryThumbnailSourceSize`.
pub fn DwmQueryThumbnailSourceSize(h_thumbnail_id: usize, psize: ?*user32.SIZE) HRESULT {
    const ps = psize orelse return E_INVALIDARG;
    const src = dwm_comp.dwmThumbnailSrcHwnd(h_thumbnail_id) orelse return E_INVALIDARG;
    var ur: user32.RECT = undefined;
    if (user32.GetWindowRect(src, &ur) == user32.FALSE) return E_INVALIDARG;
    ps.cx = ur.width();
    ps.cy = ur.height();
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
    if (st != S_OK) return st;
    if (user32.tryGetCompositorSurfaceId(hwnd)) |sid| {
        dwm_comp.enqueueIconicThumbnailRequest(sid);
    }
    return S_OK;
}
