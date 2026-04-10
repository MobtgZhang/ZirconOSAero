//! DWM 合成器 — NT 6.1 Aero（D3D9 风格重定向表面 + 高斯模糊玻璃）
//! 表面标志语义见 `src/config/dwm_surface_spec.zig`、`docs/cn/DesktopManagerSpec.md`。

const std = @import("std");
const klog = @import("../../../rtl/klog.zig");
const nt61_aero = @import("nt61_aero_defaults");
const dwm_surface_spec = @import("../../../config/dwm_surface_spec.zig");
const dwm_nt61_abi = @import("../../../config/dwm_nt61_api_contract.zig");
const fb = @import("framebuffer.zig");
const material = @import("../desktop/material.zig");
const compositor_sync_nt61 = @import("../../../config/compositor_sync_nt61.zig");

pub const CompositorBackend = enum(u8) {
    none = 0,
    aero_d3d9 = 1,
};

pub const CompositorState = enum(u8) {
    uninitialized = 0,
    initializing = 1,
    ready = 2,
    composing = 3,
    suspended = 4,
    error_state = 5,
};

pub const RedirectedSurface = struct {
    id: u16 = 0,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    z_order: i16 = 0,
    opacity: u8 = 255,
    visible: bool = true,
    dirty: bool = true,
    owner_pid: u32 = 0,
    buffer_addr: usize = 0,
    buffer_pitch: u32 = 0,
    material_type: material.MaterialType = .opaque_solid,
    corner_radius: u8 = 0,
    shadow_size: u8 = 0,
    flags: SurfaceFlags = .{},
};

pub const SurfaceFlags = dwm_surface_spec.KernelCompositorSurfaceFlags;

pub const AeroConfig = struct {
    glass_enabled: bool = nt61_aero.KernelDwm.glass_enabled,
    glass_opacity: u8 = nt61_aero.KernelDwm.glass_opacity,
    blur_radius: u8 = nt61_aero.KernelDwm.glass_blur_radius,
    blur_passes: u8 = nt61_aero.KernelDwm.glass_blur_passes,
    saturation: u8 = nt61_aero.KernelDwm.glass_saturation,
    tint_color: u32 = nt61_aero.KernelDwm.glass_tint_color,
    tint_opacity: u8 = nt61_aero.KernelDwm.glass_tint_opacity,
    specular_intensity: u8 = nt61_aero.KernelDwm.specular_intensity,
    shadow_layers: u8 = nt61_aero.KernelCompositor.shadow_layers,
    shadow_offset: u8 = nt61_aero.KernelCompositor.shadow_offset,
    peek_enabled: bool = nt61_aero.KernelCompositor.peek_enabled,
    flip3d_enabled: bool = nt61_aero.KernelCompositor.flip3d_enabled,
    animation_speed: u16 = nt61_aero.KernelCompositor.animation_speed,
    /// Shell 贴靠 / Aero Snap 策略（与 `SurfaceFlags.snap_target` 配合；行为见 DesktopManagerSpec）。
    snap_shell_enabled: bool = nt61_aero.KernelCompositor.snap_shell_enabled,
};

const MAX_SURFACES: usize = 256;

/// 每表面缩略图（任务栏 / Flip3D 共用降采样源）。Win7 级预览常见更大外包；此处 **20×15** 为 NT61 契约下的 CPU 成本 **语义子集**（2×2 盒滤 + 节流，见契约矩阵 §4.1）。
pub const surface_thumb_w: u32 = 20;
pub const surface_thumb_h: u32 = 15;
pub const surface_thumb_pixels: usize = surface_thumb_w * surface_thumb_h;

/// Per-surface DWM policy (dwmapi / `DWMWINDOWATTRIBUTE` 可映射子集)。
pub const SurfaceDwmState = struct {
    extend_margins: dwm_nt61_abi.MARGINS = .{
        .cxLeftWidth = 0,
        .cxRightWidth = 0,
        .cyTopHeight = 0,
        .cyBottomHeight = 0,
    },
    blur_dw_flags: u32 = 0,
    blur_f_enable: bool = false,
    blur_transition_on_max: bool = false,
    nc_rendering_policy: u32 = dwm_nt61_abi.DWMNCRP_USEWINDOWSTYLE,
    flip3d_policy: u32 = dwm_nt61_abi.DWMFLIP3D_DEFAULT,
    disallow_peek: bool = false,
    excluded_from_peek: bool = false,
    transitions_force_disabled: bool = false,
    allow_ncpaint: bool = true,
    force_iconic_representation: bool = false,
    nonclient_rtl: bool = false,
    cloak: bool = false,
    freeze_representation: bool = false,
    has_iconic_bitmap: bool = false,
};

var backend: CompositorBackend = .none;
var state: CompositorState = .uninitialized;
var surfaces: [MAX_SURFACES]RedirectedSurface = [_]RedirectedSurface{.{}} ** MAX_SURFACES;
/// 与 `surfaces[id]` 一一对应；`destroySurface` 时清零。
var surface_dwm: [MAX_SURFACES]SurfaceDwmState = [_]SurfaceDwmState{.{}} ** MAX_SURFACES;
var surface_count: u16 = 0;
var frame_number: u64 = 0;
var vsync_enabled: bool = true;
var wallpaper_surface_id: u16 = 0;

var aero_cfg: AeroConfig = .{};

/// 逻辑表面 ID（元数据）；实际像素指针由 `cursor_plane.zig` 在 `display.renderDesktopFrameEx` 末尾叠加。
var cursor_surface_id: u16 = 0;
var compositor_initialized: bool = false;

/// 最近一次自用户态 LPC `COMPOSITOR_TREE_SYNC_V1` 应用的世代号（0 表示尚未同步）。
var authority_tree_sync_generation_applied: u32 = 0;

pub fn getAuthorityTreeSyncGenerationApplied() u32 {
    return authority_tree_sync_generation_applied;
}

/// 阶段 C：用户态（user32 窗口 Z 序）经 csrss `compositor_tree_sync` 下推的 **权威** Z 补丁；内核不再单独 `setSurfaceZOrder` 维护并行真相。
/// `cursor_surface_id` 与壁纸占位由内核 bring-up 固定，忽略补丁中的对应 id（若有）。
pub fn applyAuthorityTreeSyncV1(generation: u32, entries: []const compositor_sync_nt61.TreeSurfaceEntryV1) void {
    if (generation == 0) return;
    authority_tree_sync_generation_applied = generation;
    for (entries) |e| {
        if (e.surface_id >= surface_count) continue;
        if (e.surface_id == cursor_surface_id) continue;
        surfaces[e.surface_id].z_order = e.z_order;
        surfaces[e.surface_id].dirty = true;
    }
}

pub fn initAero(cfg: AeroConfig) void {
    if (compositor_initialized) return;
    backend = .aero_d3d9;
    aero_cfg = cfg;
    state = .initializing;

    material.init(.glass);
    material.configureGlass(.{
        .blur_radius = cfg.blur_radius,
        .blur_passes = cfg.blur_passes,
        .tint_color = cfg.tint_color,
        .tint_opacity = cfg.tint_opacity,
        .saturation = cfg.saturation,
        .specular_intensity = cfg.specular_intensity,
    });

    allocateDesktopSurface();
    allocateCursorSurface();

    state = .ready;
    compositor_initialized = true;
    klog.info("DWM: Aero compositor initialized (glass=%s, blur=%u, shadow=%u)", .{
        @as([]const u8, if (cfg.glass_enabled) "on" else "off"),
        @as(u32, cfg.blur_radius),
        @as(u32, cfg.shadow_layers),
    });
}

pub fn createSurface(x: i32, y: i32, width: u32, height: u32, owner_pid: u32) ?u16 {
    if (surface_count >= MAX_SURFACES) return null;
    const id = surface_count;
    surfaces[id] = .{
        .id = id,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .z_order = @intCast(id),
        .owner_pid = owner_pid,
        .dirty = true,
    };
    surfaces[id].shadow_size = aero_cfg.shadow_offset;
    surface_count += 1;
    return id;
}

pub fn destroySurface(id: u16) void {
    if (id >= surface_count) return;
    surfaces[id].visible = false;
    surfaces[id].owner_pid = 0;
    surface_dwm[id] = .{};
}

fn syncDwmPolicyToKernelFlags(id: u16) void {
    if (id >= surface_count) return;
    const st = surface_dwm[id];
    surfaces[id].flags.dwm_blur_behind = st.blur_f_enable;
    surfaces[id].flags.dwm_ncrendering = st.nc_rendering_policy != dwm_nt61_abi.DWMNCRP_DISABLED;
}

pub fn getSurfaceDwmState(id: u16) ?SurfaceDwmState {
    if (id >= surface_count) return null;
    return surface_dwm[id];
}

pub fn setSurfaceExtendMargins(id: u16, m: dwm_nt61_abi.MARGINS) void {
    if (id >= surface_count) return;
    surface_dwm[id].extend_margins = m;
}

pub fn setSurfaceBlurBehind(id: u16, bb: dwm_nt61_abi.DWM_BLURBEHIND) void {
    if (id >= surface_count) return;
    const st = &surface_dwm[id];
    st.blur_dw_flags = bb.dwFlags;
    st.blur_transition_on_max = bb.fTransitionOnMaximized != 0;
    if ((bb.dwFlags & dwm_nt61_abi.DWM_BB_ENABLE) != 0) {
        st.blur_f_enable = bb.fEnable != 0;
    } else {
        st.blur_f_enable = false;
    }
    syncDwmPolicyToKernelFlags(id);
}

pub fn setSurfaceNcRenderingPolicy(id: u16, policy: u32) void {
    if (id >= surface_count) return;
    surface_dwm[id].nc_rendering_policy = policy;
    syncDwmPolicyToKernelFlags(id);
}

pub fn setSurfaceFlip3dPolicy(id: u16, policy: u32) void {
    if (id >= surface_count) return;
    surface_dwm[id].flip3d_policy = policy & 0xFF;
}

pub fn getSurfaceFlip3dPolicy(id: u16) u32 {
    if (id >= surface_count) return dwm_nt61_abi.DWMFLIP3D_DEFAULT;
    return surface_dwm[id].flip3d_policy;
}

pub fn surfaceOmittedFromFlip3dSwitcher(id: u16) bool {
    const fp = getSurfaceFlip3dPolicy(id);
    return fp == dwm_nt61_abi.DWMFLIP3D_EXCLUDEBELOW or fp == dwm_nt61_abi.DWMFLIP3D_EXCLUDEABOVE;
}

pub fn setSurfacePeekFlags(id: u16, disallow: bool, excluded: bool) void {
    if (id >= surface_count) return;
    surface_dwm[id].disallow_peek = disallow;
    surface_dwm[id].excluded_from_peek = excluded;
}

pub fn surfaceDisallowsPeek(id: u16) bool {
    if (id >= surface_count) return false;
    return surface_dwm[id].disallow_peek;
}

pub fn surfaceExcludedFromPeek(id: u16) bool {
    if (id >= surface_count) return false;
    return surface_dwm[id].excluded_from_peek;
}

pub fn surfaceDwmSetTransitionsForceDisabled(id: u16, v: bool) void {
    if (id >= surface_count) return;
    surface_dwm[id].transitions_force_disabled = v;
}

pub fn surfaceDwmSetAllowNcPaint(id: u16, v: bool) void {
    if (id >= surface_count) return;
    surface_dwm[id].allow_ncpaint = v;
}

pub fn surfaceDwmSetNonClientRtl(id: u16, v: bool) void {
    if (id >= surface_count) return;
    surface_dwm[id].nonclient_rtl = v;
}

pub fn surfaceDwmSetForceIconic(id: u16, v: bool) void {
    if (id >= surface_count) return;
    surface_dwm[id].force_iconic_representation = v;
}

pub fn surfaceDwmSetFreezeRepresentation(id: u16, v: bool) void {
    if (id >= surface_count) return;
    surface_dwm[id].freeze_representation = v;
}

pub fn setSurfaceCloak(id: u16, cloak: bool) void {
    if (id >= surface_count) return;
    surface_dwm[id].cloak = cloak;
    if (cloak) {
        surfaces[id].visible = false;
    } else {
        surfaces[id].visible = surfaces[id].owner_pid != 0;
    }
}

pub fn surfaceIsCloaked(id: u16) bool {
    if (id >= surface_count) return false;
    return surface_dwm[id].cloak;
}

pub fn moveSurface(id: u16, x: i32, y: i32) void {
    if (id >= surface_count) return;
    surfaces[id].x = x;
    surfaces[id].y = y;
    surfaces[id].dirty = true;
}

pub fn resizeSurface(id: u16, width: u32, height: u32) void {
    if (id >= surface_count) return;
    surfaces[id].width = width;
    surfaces[id].height = height;
    surfaces[id].dirty = true;
}

pub fn setSurfaceZOrder(id: u16, z: i16) void {
    if (id >= surface_count) return;
    surfaces[id].z_order = z;
}

pub fn setSurfaceMaterial(id: u16, mat: material.MaterialType) void {
    if (id >= surface_count) return;
    surfaces[id].material_type = mat;
}

pub fn setSurfaceOpacity(id: u16, opacity: u8) void {
    if (id >= surface_count) return;
    surfaces[id].opacity = opacity;
    surfaces[id].dirty = true;
}

pub fn markSurfaceDirty(id: u16) void {
    if (id >= surface_count) return;
    surfaces[id].dirty = true;
}

/// 单点写入 `RedirectedSurface.flags`（光标层等特例经 `cursorOverlayKernelSurfaceFlags`）。
pub fn setSurfaceKernelFlags(id: u16, flags: SurfaceFlags) void {
    if (id >= surface_count) return;
    surfaces[id].flags = flags;
}

fn cursorOverlayKernelSurfaceFlags() SurfaceFlags {
    return .{
        .topmost = true,
        .has_caption = false,
        .dwm_ncrendering = true,
    };
}

pub fn compose() void {
    if (state != .ready) return;
    state = .composing;

    if (backend == .aero_d3d9) {
        var i: u16 = 0;
        while (i < surface_count) : (i += 1) {
            const s = &surfaces[i];
            if (!s.visible or !s.dirty) continue;

            if (s.shadow_size > 0 and aero_cfg.glass_enabled) {
                material.renderShadow(s.x, s.y, @intCast(s.width), @intCast(s.height), s.shadow_size, 4);
            }

            if (s.material_type == .glass and aero_cfg.glass_enabled) {
                material.renderGlass(s.x, s.y, @intCast(s.width), @intCast(s.height));
            }

            s.dirty = false;
        }
    }

    state = .ready;
}

fn allocateDesktopSurface() void {
    _ = createSurface(0, 0, fb.getWidth(), fb.getHeight(), 0);
    wallpaper_surface_id = 0;
}

fn allocateCursorSurface() void {
    // 与 display 软件光标层对齐的占位表面（z_order 最高）；合成像素仍走 cursor_plane + save-under。
    const id = createSurface(0, 0, 14, 20, 0);
    if (id) |cid| {
        cursor_surface_id = cid;
        surfaces[cid].z_order = 32767;
        setSurfaceKernelFlags(cid, cursorOverlayKernelSurfaceFlags());
    }
}

pub fn getBackend() CompositorBackend {
    return backend;
}

pub fn getState() CompositorState {
    return state;
}

pub fn getSurfaceCount() u16 {
    return surface_count;
}

pub fn getFrameNumber() u64 {
    return frame_number;
}

pub fn notifyFramePresented() void {
    if (!compositor_initialized) return;
    frame_number += 1;
    const sched = @import("../../../ke/scheduler.zig");
    const now = sched.getTicks();
    var i: u16 = 0;
    while (i < surface_count) : (i += 1) {
        if (!surfaces[i].visible or surfaces[i].owner_pid == 0) continue;
        if (!surfaces[i].dirty) continue;
        refreshSurfaceThumbFromFramebuffer(i, now);
    }
}

pub fn isInitialized() bool {
    return compositor_initialized;
}

var iconic_thumbnail_serial: u64 = 0;

/// 每表面缩略像素 + 上次刷新调度 tick（节流间隔见 `thumb_refresh_min_ticks`）。
var surface_thumb_buf: [MAX_SURFACES][surface_thumb_pixels]u32 = undefined;
var surface_thumb_last_tick: [MAX_SURFACES]u64 = @splat(0);

/// 缩略图刷新最小间隔：**调度器 tick**（非毫秒）。换算：`ms ≈ ticks * (1000 / tick_hz)`；tick_hz 见 `config.sys_config.getTickRateHz()`（典型 100Hz → 20 tick ≈ 200ms，减轻任务栏悬停缩略 CPU 缩放）。
pub var thumb_refresh_min_ticks: u64 = 20;

pub fn getSurfaceZOrder(id: u16) ?i16 {
    if (id >= surface_count) return null;
    return surfaces[id].z_order;
}

pub fn isSurfaceVisible(id: u16) bool {
    if (id >= surface_count) return false;
    return surfaces[id].visible;
}

/// 只读访问缩略缓冲（无则未刷新过，可能全 0）。
pub fn getSurfaceThumbPixels(id: u16) ?[]const u32 {
    if (id >= surface_count) return null;
    return surface_thumb_buf[id][0..surface_thumb_pixels];
}

fn refreshSurfaceThumbFromFramebuffer(id: u16, now_tick: u64) void {
    if (id >= surface_count or !surfaces[id].visible) return;
    const s0 = surfaces[id];
    if (s0.width == 0 or s0.height == 0) return;
    const prev = surface_thumb_last_tick[id];
    if (prev != 0 and now_tick -% prev < thumb_refresh_min_ticks) return;
    surface_thumb_last_tick[id] = now_tick;

    const s = surfaces[id];
    const fw: i64 = @intCast(fb.getWidth());
    const fh: i64 = @intCast(fb.getHeight());
    if (fw <= 0 or fh <= 0) return;
    const sw: i64 = @max(1, @as(i64, @intCast(s.width)));
    const sh: i64 = @max(1, @as(i64, @intCast(s.height)));
    const x0 = @as(i64, s.x);
    const y0 = @as(i64, s.y);

    var ty: u32 = 0;
    while (ty < surface_thumb_h) : (ty += 1) {
        var tx: u32 = 0;
        while (tx < surface_thumb_w) : (tx += 1) {
            const u_tx: i64 = @intCast(tx);
            const u_ty: i64 = @intCast(ty);
            const sx64 = x0 + @divTrunc(u_tx * sw, @as(i64, @intCast(surface_thumb_w)));
            const sy64 = y0 + @divTrunc(u_ty * sh, @as(i64, @intCast(surface_thumb_h)));
            const sx = std.math.clamp(sx64, 0, fw - 1);
            const sy = std.math.clamp(sy64, 0, fh - 1);
            const sx1 = @min(sx + 1, fw - 1);
            const sy1 = @min(sy + 1, fh - 1);
            var rr: u32 = 0;
            var gg: u32 = 0;
            var bb: u32 = 0;
            for ([_]i64{ 0, 1 }) |ox| {
                for ([_]i64{ 0, 1 }) |oy| {
                    const px = if (ox == 0) sx else sx1;
                    const py = if (oy == 0) sy else sy1;
                    const c = fb.getPixel32(@intCast(px), @intCast(py));
                    rr += c & 0xFF;
                    gg += (c >> 8) & 0xFF;
                    bb += (c >> 16) & 0xFF;
                }
            }
            surface_thumb_buf[id][ty * surface_thumb_w + tx] = (rr / 4) | ((gg / 4) << 8) | ((bb / 4) << 16) | 0xFF000000;
        }
    }
}

pub const flip3d_shell_sid_buffer_cap = dwm_nt61_abi.flip3d_shell_sid_buffer_cap;
pub const flip3d_shell_thumb_paint_max = dwm_nt61_abi.flip3d_shell_thumb_paint_max;

/// 供 Flip3D / 调试：收集「像用户窗」的表面（略过壁纸/光标占位等）。写入不超过 `buf.len`；返回值 ≤ `buf.len`。
pub fn collectShellWindowSurfaceIds(buf: []u16) usize {
    var n: usize = 0;
    var i: u16 = 0;
    while (i < surface_count) : (i += 1) {
        const s = surfaces[i];
        if (!s.visible or s.owner_pid == 0) continue;
        if (s.width < 16 or s.height < 16) continue;
        if (s.z_order >= 30000) continue;
        const fp = surface_dwm[i].flip3d_policy;
        // Ref: Learn — `DWMFLIP3D_*` 将窗口从 Flip3D 切换器中省略；本子集对两种非 DEFAULT 均不收集到底栏预览。
        if (fp == dwm_nt61_abi.DWMFLIP3D_EXCLUDEBELOW or fp == dwm_nt61_abi.DWMFLIP3D_EXCLUDEABOVE)
            continue;
        if (n < buf.len) buf[n] = i;
        n += 1;
    }
    return n;
}

/// `WM_DWMSENDICONICTHUMBNAIL` / 任务栏缩略图请求计数（与 `display` 壳层采样帧缓冲配合；语义见 MS Learn DWM 消息）。
pub fn enqueueIconicThumbnailRequest(surface_id: u16) void {
    if (!compositor_initialized or surface_id >= surface_count) return;
    iconic_thumbnail_serial +%= 1;
    const sched = @import("../../../ke/scheduler.zig");
    const now = sched.getTicks();
    const prev = surface_thumb_last_tick[surface_id];
    if (prev != 0 and now -% prev < thumb_refresh_min_ticks) return;
    refreshSurfaceThumbFromFramebuffer(surface_id, now);
}

pub fn iconicThumbnailSerial() u64 {
    return iconic_thumbnail_serial;
}

pub fn getAeroConfig() *const AeroConfig {
    return &aero_cfg;
}

// ── dwmapi 缩略图句柄（`HTHUMBNAIL` 语义：本仓库为内核递增槽位 +1） ──

const MAX_DWM_THUMBNAILS: usize = 32;

var thumb_slot_used: [MAX_DWM_THUMBNAILS]bool = [_]bool{false} ** MAX_DWM_THUMBNAILS;
var thumb_dest_hwnd: [MAX_DWM_THUMBNAILS]u64 = undefined;
var thumb_src_hwnd: [MAX_DWM_THUMBNAILS]u64 = undefined;
var thumb_props_store: [MAX_DWM_THUMBNAILS]dwm_nt61_abi.DWM_THUMBNAIL_PROPERTIES = undefined;

fn defaultThumbnailProps() dwm_nt61_abi.DWM_THUMBNAIL_PROPERTIES {
    return .{
        .dwFlags = dwm_nt61_abi.DWM_TNP_VISIBLE,
        ._pad_dwalign = 0,
        .rcDestination = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .rcSource = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .opacity = 255,
        ._pad_opacity = 0,
        ._pad_opacity2 = 0,
        ._pad_opacity3 = 0,
        .fVisible = 1,
        .fSourceClientAreaOnly = 0,
    };
}

/// `handle` 为 1..MAX_DWM_THUMBNAILS；失败返回 null（表满或自引用）。
pub fn dwmThumbnailRegister(dest_hwnd: u64, src_hwnd: u64) ?usize {
    if (dest_hwnd == src_hwnd) return null;
    var i: usize = 0;
    while (i < MAX_DWM_THUMBNAILS) : (i += 1) {
        if (!thumb_slot_used[i]) {
            thumb_slot_used[i] = true;
            thumb_dest_hwnd[i] = dest_hwnd;
            thumb_src_hwnd[i] = src_hwnd;
            thumb_props_store[i] = defaultThumbnailProps();
            return i + 1;
        }
    }
    return null;
}

pub fn dwmThumbnailUnregister(handle: usize) bool {
    if (handle == 0 or handle > MAX_DWM_THUMBNAILS) return false;
    const i = handle - 1;
    if (!thumb_slot_used[i]) return false;
    thumb_slot_used[i] = false;
    return true;
}

pub fn dwmThumbnailUpdate(handle: usize, props: *const dwm_nt61_abi.DWM_THUMBNAIL_PROPERTIES) bool {
    if (handle == 0 or handle > MAX_DWM_THUMBNAILS) return false;
    const i = handle - 1;
    if (!thumb_slot_used[i]) return false;
    thumb_props_store[i] = props.*;
    return true;
}

pub fn dwmThumbnailSrcHwnd(handle: usize) ?u64 {
    if (handle == 0 or handle > MAX_DWM_THUMBNAILS) return null;
    const i = handle - 1;
    if (!thumb_slot_used[i]) return null;
    return thumb_src_hwnd[i];
}

/// `HTHUMBNAIL` 句柄 1..MAX；未使用槽返回 null。
pub fn dwmThumbnailDestHwnd(handle: usize) ?u64 {
    if (handle == 0 or handle > MAX_DWM_THUMBNAILS) return null;
    const i = handle - 1;
    if (!thumb_slot_used[i]) return null;
    return thumb_dest_hwnd[i];
}

/// 供 `display` 将注册缩略图合成到帧缓冲；无效句柄返回 null。
pub fn dwmThumbnailPropsConst(handle: usize) ?*const dwm_nt61_abi.DWM_THUMBNAIL_PROPERTIES {
    if (handle == 0 or handle > MAX_DWM_THUMBNAILS) return null;
    const i = handle - 1;
    if (!thumb_slot_used[i]) return null;
    return &thumb_props_store[i];
}

pub const max_registered_dwm_thumbnails = MAX_DWM_THUMBNAILS;

/// 单元测试 / 诊断：重置缩略图表。
pub fn dwmThumbnailResetForTest() void {
    @memset(&thumb_slot_used, false);
}

// ── Flip3D 覆盖层（内核）↔ 用户态 `flip3d_preview_enabled` 诊断桥 ──

var flip3d_overlay_kernel_active: bool = false;

pub fn notifyFlip3dOverlayKernelActive(active: bool) void {
    flip3d_overlay_kernel_active = active;
}

pub fn isFlip3dOverlayKernelActive() bool {
    return flip3d_overlay_kernel_active;
}
