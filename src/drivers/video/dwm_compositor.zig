//! DWM 合成器 — NT 6.1 Aero（D3D9 风格重定向表面 + 高斯模糊玻璃）
//! 表面标志语义见 `src/config/dwm_surface_spec.zig`、`docs/cn/DesktopManagerSpec.md`。

const klog = @import("../../rtl/klog.zig");
const nt61_aero = @import("nt61_aero_defaults");
const dwm_surface_spec = @import("../../config/dwm_surface_spec.zig");
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

const MAX_SURFACES: usize = 128;

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
        surfaces[cid].flags.topmost = true;
        surfaces[cid].flags.has_caption = false;
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
}

pub fn isInitialized() bool {
    return compositor_initialized;
}

/// 占位：`WM_DWMSENDICONICTHUMBNAIL` / 任务栏缩略图协议（NT 6.1 DWM）；依赖离屏表面与 Shell 队列后实现。
pub fn enqueueIconicThumbnailRequest(_: u16) void {}

pub fn getAeroConfig() *const AeroConfig {
    return &aero_cfg;
}
