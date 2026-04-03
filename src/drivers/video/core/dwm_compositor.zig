//! DWM 合成器 — NT 6.1 Aero（D3D9 风格重定向表面 + 高斯模糊玻璃）
//! 表面标志语义见 `src/config/dwm_surface_spec.zig`、`docs/cn/DesktopManagerSpec.md`。

const std = @import("std");
const klog = @import("../../rtl/klog.zig");
const nt61_aero = @import("nt61_aero_defaults");
const dwm_surface_spec = @import("../../config/dwm_surface_spec.zig");
const dwm_nt61_abi = @import("../../config/dwm_nt61_api_contract.zig");
const fb = @import("framebuffer.zig");
const material = @import("material.zig");

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

var backend: CompositorBackend = .none;
var state: CompositorState = .uninitialized;
var surfaces: [MAX_SURFACES]RedirectedSurface = [_]RedirectedSurface{.{}} ** MAX_SURFACES;
var surface_count: u16 = 0;
var frame_number: u64 = 0;
var vsync_enabled: bool = true;
var wallpaper_surface_id: u16 = 0;

var aero_cfg: AeroConfig = .{};

/// 逻辑表面 ID（元数据）；实际像素指针由 `cursor_plane.zig` 在 `display.renderDesktopFrameEx` 末尾叠加。
var cursor_surface_id: u16 = 0;
var compositor_initialized: bool = false;

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
    const sched = @import("../../ke/scheduler.zig");
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
            surface_thumb_buf[id][ty * surface_thumb_w + tx] = (rr / 4) | ((gg / 4) << 8) | ((bb / 4) << 16);
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
        if (n < buf.len) buf[n] = i;
        n += 1;
    }
    return n;
}

/// `WM_DWMSENDICONICTHUMBNAIL` / 任务栏缩略图请求计数（与 `display` 壳层采样帧缓冲配合；语义见 MS Learn DWM 消息）。
pub fn enqueueIconicThumbnailRequest(surface_id: u16) void {
    if (!compositor_initialized or surface_id >= surface_count) return;
    iconic_thumbnail_serial +%= 1;
    const sched = @import("../../ke/scheduler.zig");
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
