//! Graphical framebuffer miniport (NT6: analog to display miniport + surface IOCTLs)
//! Pixel primitives, bulk ops, and IRP/IOCTL dispatch for the DWM/compositor path.
//! Framebuffer driver; registers `\\Driver\\Framebuf` / `\\Device\\Framebuf0`.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../../../io/io.zig");
const klog = @import("../../../rtl/klog.zig");
const cjk_font = @import("../../../desktop/kernel/font/cjk_font.zig");
const virtio_gpu_spec = @import("../virtio/virtio_gpu_spec.zig");
const config_mod = @import("../../../config/config.zig");
const frame_mod = @import("../../../mm/frame.zig");
const phys_pb = @import("../../../mm/phys_buddy.zig");
const vm = @import("../../../mm/vm.zig");

// ── Pixel Format ──

pub const PixelFormat = enum(u8) {
    rgb565 = 0,
    rgb888 = 1,
    xrgb8888 = 2,
    argb8888 = 3,
    bgr888 = 4,
    xbgr8888 = 5,
    indexed_8bpp = 6,
};

pub fn RGB(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) << 16 | @as(u32, g) << 8 | @as(u32, b);
}

pub fn ARGB(a: u8, r: u8, g: u8, b: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, r) << 16 | @as(u32, g) << 8 | @as(u32, b);
}

pub fn getRed(color: u32) u8 {
    return @truncate((color >> 16) & 0xFF);
}

pub fn getGreen(color: u32) u8 {
    return @truncate((color >> 8) & 0xFF);
}

pub fn getBlue(color: u32) u8 {
    return @truncate(color & 0xFF);
}

pub fn getAlpha(color: u32) u8 {
    return @truncate((color >> 24) & 0xFF);
}

// ── Framebuffer Configuration ──

pub const FramebufferConfig = struct {
    address: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    bpp: u8 = 0,
    pixel_format: PixelFormat = .xrgb8888,
    double_buffer: bool = false,
    /// true：显存为 BGRx（首字节蓝，UEFI/QEMU GOP 常见）；false：RGBx（首字节红）
    pixel_bgr: bool = true,
};

// ── Rect / Point types ──

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.x + other.w and self.x + self.w > other.x and
            self.y < other.y + other.h and self.y + self.h > other.y;
    }
};

/// 虚拟桌面上的监视器布局（NT 6.1 多监视器 / DPI 概念的简化内核模型；单 GOP 时仅一项）。
/// 脏矩形与命中测试使用 **物理像素**，与 `Rect` 同一坐标系；`effective_dpi_*` 供 Shell 逻辑坐标换算。
/// Ref: https://learn.microsoft.com/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows
pub const MonitorLayoutNt61 = struct {
    id: u32 = 0,
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    width_px: u32 = 0,
    height_px: u32 = 0,
    /// 有效 DPI，默认 96（100%）。用于 `physicalToLogicalPx`。
    effective_dpi_x: u16 = 96,
    effective_dpi_y: u16 = 96,
};

const MAX_MONITORS_NT61: usize = 4;
var monitor_layouts: [MAX_MONITORS_NT61]MonitorLayoutNt61 = [_]MonitorLayoutNt61{.{}} ** MAX_MONITORS_NT61;
var monitor_layout_count: u32 = 0;

fn syncMonitorLayoutsFromPrimary() void {
    monitor_layout_count = 0;
    if (!config_ready or fb_config.width == 0 or fb_config.height == 0) return;
    monitor_layouts[0] = .{
        .id = 0,
        .origin_x = 0,
        .origin_y = 0,
        .width_px = fb_config.width,
        .height_px = fb_config.height,
        .effective_dpi_x = 96,
        .effective_dpi_y = 96,
    };
    monitor_layout_count = 1;
}

pub fn getMonitorLayoutCount() u32 {
    return monitor_layout_count;
}

pub fn getMonitorLayout(index: u32) ?MonitorLayoutNt61 {
    if (index >= monitor_layout_count) return null;
    return monitor_layouts[index];
}

/// 物理像素坐标 → 逻辑像素（96 DPI 基准）。`dpi` 为 0 时按 96 处理。
pub fn physicalToLogicalPx(dpi: u16, physical_px: i32) i32 {
    const d: i64 = if (dpi == 0) 96 else @intCast(dpi);
    return @intCast(@divTrunc(@as(i64, physical_px) * 96, @max(1, d)));
}

/// `virtual` 外包：当前等于主监视器矩形；多监视器扩展时合并各 `MonitorLayoutNt61`。
pub fn getVirtualDesktopBounds() Rect {
    if (monitor_layout_count == 0) return .{};
    var r = Rect{
        .x = monitor_layouts[0].origin_x,
        .y = monitor_layouts[0].origin_y,
        .w = @as(i32, @intCast(monitor_layouts[0].width_px)),
        .h = @as(i32, @intCast(monitor_layouts[0].height_px)),
    };
    var i: u32 = 1;
    while (i < monitor_layout_count) : (i += 1) {
        const m = monitor_layouts[i];
        const mx2 = @as(i64, m.origin_x) + @as(i64, @intCast(m.width_px));
        const my2 = @as(i64, m.origin_y) + @as(i64, @intCast(m.height_px));
        const rx2 = @as(i64, r.x) + @as(i64, r.w);
        const ry2 = @as(i64, r.y) + @as(i64, r.h);
        const nx0 = @min(@as(i64, r.x), @as(i64, m.origin_x));
        const ny0 = @min(@as(i64, r.y), @as(i64, m.origin_y));
        const nx1 = @max(rx2, mx2);
        const ny1 = @max(ry2, my2);
        r.x = @intCast(nx0);
        r.y = @intCast(ny0);
        r.w = @intCast(nx1 - nx0);
        r.h = @intCast(ny1 - ny0);
    }
    return r;
}

/// `origin + delta` 与 `limit` 比较后再截断为 u32，避免 `x0 + w` 在 u32 上先溢出（Debug 下 panic）。
fn addU32Clamped(origin: u32, delta: u32, limit: u32) u32 {
    const s = @as(u64, origin) + @as(u64, delta);
    const l = @as(u64, limit);
    return @intCast(@min(s, l));
}

/// `y * pitch + x * bytes_pp`，u64 中间值避免 u32 乘法在 Debug 下溢出。
fn pixelByteOffset(x: u32, y: u32, bytes_pp: u32) usize {
    const p = @as(u64, y) * @as(u64, fb_config.pitch) + @as(u64, x) * @as(u64, bytes_pp);
    return @intCast(p);
}

// ── Dirty Region Tracking ──

const MAX_DIRTY_RECTS: usize = 32;

var dirty_rects: [MAX_DIRTY_RECTS]Rect = [_]Rect{.{}} ** MAX_DIRTY_RECTS;
var dirty_count: usize = 0;

fn dirtyRectUnion2(a: Rect, b: Rect) Rect {
    const ax1 = a.x + a.w;
    const ay1 = a.y + a.h;
    const bx1 = b.x + b.w;
    const by1 = b.y + b.h;
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(ax1, bx1);
    const y1 = @max(ay1, by1);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// 并入脏矩形列表：与已有矩形**相交**则合并为一项，减轻 `dirty_count` 顶满后被迫整屏回退（CPU 合成路径）。
pub fn addDirtyRect(r: Rect) void {
    if (r.w <= 0 or r.h <= 0) return;
    var nr = r;
    var i: usize = 0;
    // 优化：合并后继续从当前位置检查（不必重置为0），避免 O(n²) 中不必要的重复遍历
    while (i < dirty_count) {
        if (dirty_rects[i].intersects(nr)) {
            nr = dirtyRectUnion2(dirty_rects[i], nr);
            dirty_rects[i] = dirty_rects[dirty_count - 1];
            dirty_count -= 1;
            // 不重置 i = 0，继续从当前 i 检查新合并的矩形
            continue;
        }
        i += 1;
    }
    if (dirty_count < MAX_DIRTY_RECTS) {
        dirty_rects[dirty_count] = nr;
        dirty_count += 1;
    } else {
        markFullScreenDirty();
    }
}

pub fn markDirtyRegion(x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 0 or h <= 0) return;
    addDirtyRect(.{ .x = x, .y = y, .w = w, .h = h });
}

pub fn markFullScreenDirty() void {
    dirty_count = MAX_DIRTY_RECTS;
}

/// 当前待 `flipDirty` 的脏矩形轴对齐外包（`dirty_count >= MAX` 视为整屏回退，返回 `null`）。不修改 dirty 状态。
pub fn peekDirtyUnionPx() ?Rect {
    if (dirty_count == 0 or dirty_count >= MAX_DIRTY_RECTS) return null;
    var ux0: i32 = 0;
    var uy0: i32 = 0;
    var ux1: i32 = 0;
    var uy1: i32 = 0;
    var first = true;
    const fw: i32 = @intCast(fb_config.width);
    const fh: i32 = @intCast(fb_config.height);
    for (dirty_rects[0..dirty_count]) |r| {
        const rx0: i32 = @max(r.x, 0);
        const ry0: i32 = @max(r.y, 0);
        const rw: i32 = @max(r.w, 0);
        const rh: i32 = @max(r.h, 0);
        if (rw == 0 or rh == 0) continue;
        const rx1: i32 = @min(rx0 + rw, fw);
        const ry1: i32 = @min(ry0 + rh, fh);
        if (rx0 >= rx1 or ry0 >= ry1) continue;
        if (first) {
            ux0 = rx0;
            uy0 = ry0;
            ux1 = rx1;
            uy1 = ry1;
            first = false;
        } else {
            ux0 = @min(ux0, rx0);
            uy0 = @min(uy0, ry0);
            ux1 = @max(ux1, rx1);
            uy1 = @max(uy1, ry1);
        }
    }
    if (first) return null;
    return .{ .x = ux0, .y = uy0, .w = ux1 - ux0, .h = uy1 - uy0 };
}

// ── Driver State ──

var fb_config: FramebufferConfig = .{};
var back_buffer_addr: usize = 0;
var back_buffer_size: usize = 0;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;
var config_ready: bool = false;
var total_draw_calls: u64 = 0;
var total_flips: u64 = 0;

// ── Double / triple off-screen buffering ──
// 双缓冲：单离屏槽 + GOP。三缓冲（乒乓）：两离屏槽 + GOP；present 后切换 draw_slot（概念见 docs/cn/AeroDesktopRuntime.md §9，自研非 DXGI）。
// 单缓冲（double_buffer_active=false）：getDrawBuffer() 即 GOP；flipDirty() 仅清 dirty 计数、不做 memcpy（屏前直绘 + 软件光标 save-under 同面）。
// 路线图：与用户态 DWM 共享合成缓冲时，优先改为 `NtCreateSection` + 跨进程 `NtMapViewOfSection`（见 docs/cn/MM_Section_Roadmap.md、docs/cn/DesktopManagerSpec.md）。

/// 小型静态缓冲区阈值（覆盖 800×600@32bpp ≈ 1.8MB 以内的单缓冲）
const STATIC_BACK_BUF_MAX: usize = 2 * 1024 * 1024;

/// 静态缓冲区：仅用于小分辨率（<=800×600@32bpp）情况，避免堆分配开销
var back_buf: [STATIC_BACK_BUF_MAX]u8 align(1) = undefined;

/// 标记静态缓冲区是否已初始化（避免不必要的 memset）
var back_buf_initialized: bool = false;
var double_buffer_active: bool = false;
/// 第二离屏槽；flip 提交后 draw_slot 翻转。
var triple_buffer_active: bool = false;
var draw_slot: u32 = 0;
/// 单槽字节数 (= pitch*height)。
var bytes_per_slot: usize = 0;
/// `allocContiguous` / 伙伴优先路径后备时使用；可能容纳 1 或 2 槽。
var back_buffer_heap_nframes: usize = 0;
/// 与 `phys_buddy.allocContiguousPagesWithSource` 配对释放。
var back_heap_contig_source: phys_pb.ContiguousSource = .frame_bitmap;
var back_heap_contig_order: u5 = 0;

// ── IOCTL Codes ──

pub const IOCTL_FB_GET_CONFIG: u32 = 0x00090000;
pub const IOCTL_FB_SET_CONFIG: u32 = 0x00090004;
pub const IOCTL_FB_MAP_BUFFER: u32 = 0x00090008;
pub const IOCTL_FB_FLIP: u32 = 0x0009000C;
pub const IOCTL_FB_FILL_RECT: u32 = 0x00090010;
pub const IOCTL_FB_COPY_RECT: u32 = 0x00090014;
pub const IOCTL_FB_DRAW_LINE: u32 = 0x00090018;
pub const IOCTL_FB_GET_STATS: u32 = 0x0009001C;

/// IOCTL_FB_FILL_RECT 请求结构（NT6.1 framebuffer miniport 约定）
pub const FillRectRequest = extern struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: u32,
};

comptime {
    std.debug.assert(@sizeOf(FillRectRequest) == 20);
}

/// IOCTL_FB_COPY_RECT 请求结构：矩形区域拷贝
pub const CopyRectRequest = extern struct {
    src_x: i32,
    src_y: i32,
    dst_x: i32,
    dst_y: i32,
    w: i32,
    h: i32,
};

comptime {
    std.debug.assert(@sizeOf(CopyRectRequest) == 24);
}

/// IOCTL_FB_DRAW_LINE 请求结构
pub const DrawLineRequest = extern struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    color: u32,
};

comptime {
    std.debug.assert(@sizeOf(DrawLineRequest) == 20);
}

/// IOCTL_FB_GET_STATS 响应结构
pub const FbStatsResponse = extern struct {
    total_draw_calls: u64,
    total_flips: u64,
    width: u32,
    height: u32,
    bpp: u8,
    double_buffer_active: bool,
    triple_buffer_active: bool,
    reserved: [2]u8 = [_]u8{0} ** 2,
};

comptime {
    std.debug.assert(@sizeOf(FbStatsResponse) == 32);
}

// ── Internal Helpers ──

fn activeDrawSlotOffset() usize {
    if (triple_buffer_active) return @as(usize, draw_slot) * bytes_per_slot;
    return 0;
}

fn drawBufferBytePtr() [*]u8 {
    const off = activeDrawSlotOffset();
    if (back_buffer_addr != 0) {
        return @ptrFromInt(back_buffer_addr + off);
    }
    return @as([*]u8, @ptrCast(&back_buf)) + off;
}

fn getDrawBuffer() [*]volatile u8 {
    if (double_buffer_active) {
        return @volatileCast(drawBufferBytePtr());
    }
    return @ptrFromInt(fb_config.address);
}

fn backBufSrcPtr() [*]const u8 {
    return drawBufferBytePtr();
}

/// Pre-pack a color into the native pixel word so that solid fills can write
/// one u32 per pixel instead of four individual bytes.
fn packPixel32(color: u32) u32 {
    if (fb_config.pixel_bgr) {
        return color | 0xFF000000;
    } else {
        const b = color & 0xFF;
        const g = (color >> 8) & 0xFF;
        const r = (color >> 16) & 0xFF;
        return r | (g << 8) | (b << 16) | 0xFF000000;
    }
}

/// color 为与 `display.rgb` 一致：低 8 位 B，中 G，高 R（无 Alpha 语义）
fn writePixel4(ptr: [*]volatile u8, offset: usize, color: u32) void {
    const b = color & 0xFF;
    const g = (color >> 8) & 0xFF;
    const r = (color >> 16) & 0xFF;
    if (fb_config.pixel_bgr) {
        ptr[offset] = @truncate(b);
        ptr[offset + 1] = @truncate(g);
        ptr[offset + 2] = @truncate(r);
    } else {
        ptr[offset] = @truncate(r);
        ptr[offset + 1] = @truncate(g);
        ptr[offset + 2] = @truncate(b);
    }
    // XRGB：Alpha 为 0 时部分固件/合成路径会当作全透明，强制不透明
    ptr[offset + 3] = 0xFF;
}

fn writePixel3(ptr: [*]volatile u8, offset: usize, color: u32) void {
    const b = color & 0xFF;
    const g = (color >> 8) & 0xFF;
    const r = (color >> 16) & 0xFF;
    if (fb_config.pixel_bgr) {
        ptr[offset] = @truncate(b);
        ptr[offset + 1] = @truncate(g);
        ptr[offset + 2] = @truncate(r);
    } else {
        ptr[offset] = @truncate(r);
        ptr[offset + 1] = @truncate(g);
        ptr[offset + 2] = @truncate(b);
    }
}

// ── Pixel Operations ──

pub fn putPixel32(x: u32, y: u32, color: u32) void {
    if (x >= fb_config.width or y >= fb_config.height) return;
    const bpp = fb_config.bpp;
    const bytes_pp = @as(u32, bpp) / 8;
    const offset = pixelByteOffset(x, y, bytes_pp);
    const ptr = getDrawBuffer();

    if (bytes_pp >= 4) {
        writePixel4(ptr, offset, color);
    } else if (bytes_pp == 3) {
        writePixel3(ptr, offset, color);
    } else if (bytes_pp == 2) {
        const r: u16 = @truncate((color >> 19) & 0x1F);
        const g: u16 = @truncate((color >> 10) & 0x3F);
        const b: u16 = @truncate((color >> 3) & 0x1F);
        const c16: u16 = (r << 11) | (g << 5) | b;
        ptr[offset] = @truncate(c16);
        ptr[offset + 1] = @truncate(c16 >> 8);
    }
}

pub fn getPixel32(x: u32, y: u32) u32 {
    if (x >= fb_config.width or y >= fb_config.height) return 0;
    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const offset = pixelByteOffset(x, y, bytes_pp);
    const ptr = getDrawBuffer();

    if (bytes_pp >= 3) {
        if (fb_config.pixel_bgr) {
            return @as(u32, ptr[offset]) |
                (@as(u32, ptr[offset + 1]) << 8) |
                (@as(u32, ptr[offset + 2]) << 16) |
                if (bytes_pp == 4) (@as(u32, ptr[offset + 3]) << 24) else 0;
        } else {
            const pr = ptr[offset];
            const pg = ptr[offset + 1];
            const pb = ptr[offset + 2];
            const pa = if (bytes_pp == 4) ptr[offset + 3] else 0;
            return pb | (@as(u32, pg) << 8) | (@as(u32, pr) << 16) | (@as(u32, pa) << 24);
        }
    }
    return 0;
}

/// Alpha-blend a single pixel at (x, y) with the given color and alpha.
/// Used by material effects like Reveal Highlight.
pub fn blendPixel(x: u32, y: u32, color: u32, alpha: u8) void {
    if (x >= fb_config.width or y >= fb_config.height) return;
    if (alpha == 0) return;
    const existing = getPixel32(x, y);
    const er: u32 = (existing >> 0) & 0xFF;
    const eg: u32 = (existing >> 8) & 0xFF;
    const eb: u32 = (existing >> 16) & 0xFF;
    const cr: u32 = (color >> 0) & 0xFF;
    const cg: u32 = (color >> 8) & 0xFF;
    const cb: u32 = (color >> 16) & 0xFF;
    const a: u32 = @intCast(alpha);
    const inv: u32 = 255 - a;
    const nr = (er * inv + cr * a) / 255;
    const ng = (eg * inv + cg * a) / 255;
    const nb = (eb * inv + cb * a) / 255;
    putPixel32(x, y, nr | (ng << 8) | (nb << 16));
}

/// 批量混合单行像素: 逐像素 alpha 混合(原地写回).
/// 比逐个调用 `blendPixel` 减少函数调用开销(外层循环由调用方管理).
/// @param y: 目标行 Y 坐标
/// @param x0/x1: 水平范围 [x0, x1)
/// @param color: 源颜色(仅 RGB 分量有效,alpha 由 alpha 参数提供)
/// @param alpha: 源透明度 [0-255]
pub fn blendPixelRow(y: u32, x0: u32, x1: u32, color: u32, alpha: u8) void {
    if (alpha == 0 or x0 >= x1 or y >= fb_config.height) return;
    const cx = @min(x0, fb_config.width);
    const cx1 = @min(x1, fb_config.width);
    if (cx >= cx1) return;

    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();
    const row_offset = pixelByteOffset(cx, y, bytes_pp);
    const count = cx1 - cx;

    if (bytes_pp == 4) {
        const cr: u8 = @truncate(color);
        const cg: u8 = @truncate(color >> 8);
        const cb: u8 = @truncate(color >> 16);
        const a = @as(u32, alpha);
        const inv = 255 - a;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const px_off = row_offset + @as(usize, i) * 4;
            const b = ptr[px_off];
            const g = ptr[px_off + 1];
            const r = ptr[px_off + 2];
            const nr = @as(u32, r) * inv + cr * a;
            const ng = @as(u32, g) * inv + cg * a;
            const nb = @as(u32, b) * inv + cb * a;
            ptr[px_off] = @truncate((nr) / 255);
            ptr[px_off + 1] = @truncate((ng) / 255);
            ptr[px_off + 2] = @truncate((nb) / 255);
        }
    } else {
        // 回退到逐像素
        var x: u32 = cx;
        while (x < cx1) : (x += 1) {
            blendPixel(x, y, color, alpha);
        }
    }
}

/// 批量写入单行像素(无 alpha 混合,直接覆盖).
/// 比逐个调用 `putPixel32` 减少函数调用开销.
/// @param y: 目标行 Y 坐标
/// @param x0/x1: 水平范围 [x0, x1)
/// @param color: ARGB 颜色
pub fn putPixelRow(y: u32, x0: u32, x1: u32, color: u32) void {
    if (x0 >= x1 or y >= fb_config.height) return;
    const cx = @min(x0, fb_config.width);
    const cx1 = @min(x1, fb_config.width);
    if (cx >= cx1) return;

    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();
    const row_offset = pixelByteOffset(cx, y, bytes_pp);
    const count = cx1 - cx;

    if (bytes_pp == 4) {
        const pxval = packPixel32(color);
        const base = @intFromPtr(ptr) + row_offset;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const word_ptr: *align(1) volatile u32 = @ptrFromInt(base + @as(usize, i) * 4);
            word_ptr.* = pxval;
        }
    } else if (bytes_pp == 3) {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            writePixel3(ptr, row_offset + @as(usize, i) * 3, color);
        }
    } else {
        var x: u32 = cx;
        while (x < cx1) : (x += 1) {
            putPixel32(x, y, color);
        }
    }
}

/// 直接写入一行像素(span): 接收已计算好的行首偏移,避免重复调用 `pixelByteOffset`.
/// @param ptr_base: 帧缓冲基址指针(来自 getDrawBuffer)
/// @param row_byte_offset: 该行像素数据的字节偏移量
/// @param x0/x1: 水平范围 [x0, x1)
/// @param color: ARGB 颜色
/// @param bytes_per_pixel: 每像素字节数(必须为 4)
pub fn putSpanDirect(ptr_base: [*]volatile u8, row_byte_offset: usize, x0: u32, x1: u32, color: u32, bytes_per_pixel: u32) void {
    if (x0 >= x1) return;
    const count = x1 - x0;
    if (bytes_per_pixel == 4) {
        var pxval: u32 = color;
        if (!fb_config.pixel_bgr) {
            // packPixel32: RGB -> XRGB
            pxval = color | 0xFF000000;
        } else {
            // BGR 顺序: 交换 R 和 B
            const b = color & 0xFF;
            const g = (color >> 8) & 0xFF;
            const r = (color >> 16) & 0xFF;
            pxval = (r) | (g << 8) | (b << 16) | 0xFF000000;
        }
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const word_ptr: *align(1) volatile u32 = @ptrFromInt(@intFromPtr(ptr_base) + row_byte_offset + @as(usize, i) * 4);
            word_ptr.* = pxval;
        }
    }
}

/// Blit a RGBA bitmap to the framebuffer at (screen_x, screen_y).
/// This function handles alpha blending (premultiplied alpha) for smooth icon/logo rendering.
/// @param rgba: pointer to RGBA pixel data (each pixel is 4 bytes: R, G, B, A in that order)
/// @param src_w: width of the source bitmap
/// @param src_h: height of the source bitmap
/// @param screen_x: X coordinate on screen (top-left corner)
/// @param screen_y: Y coordinate on screen (top-left corner)
/// @param scale: scale factor (1 = no scaling, 2 = 2x scale, etc.)
pub fn blitRgba(
    rgba: [*]const u8,
    src_w: u32,
    src_h: u32,
    screen_x: i32,
    screen_y: i32,
    scale: u32,
) void {
    if (src_w == 0 or src_h == 0) return;
    const s: u32 = if (scale < 1) 1 else scale;
    const dst_w: u32 = src_w * s;
    const dst_h: u32 = src_h * s;

    if (dst_w == 0 or dst_h == 0) return;

    // 处理负坐标（源图像裁剪）
    const sx0: u32 = if (screen_x < 0) @intCast(-screen_x) else 0;
    const sy0: u32 = if (screen_y < 0) @intCast(-screen_y) else 0;
    if (sx0 >= src_w or sy0 >= src_h) return;

    const x0: u32 = if (screen_x < 0) 0 else @intCast(screen_x);
    const y0: u32 = if (screen_y < 0) 0 else @intCast(screen_y);
    if (x0 >= fb_config.width or y0 >= fb_config.height) return;

    const x1: u32 = @min(x0 + dst_w, fb_config.width);
    const y1: u32 = @min(y0 + dst_h, fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    // 最近邻缩放：从目标像素反推源像素坐标
    const inv_scale_x: f64 = @as(f64, @floatFromInt(src_w)) / @as(f64, @floatFromInt(dst_w));
    const inv_scale_y: f64 = @as(f64, @floatFromInt(src_h)) / @as(f64, @floatFromInt(dst_h));

    var dy: u32 = y0;
    var sy_float: f64 = @as(f64, @floatFromInt(sy0)) * inv_scale_y;
    while (dy < y1) : (dy += 1) {
        const src_y: u32 = @min(@as(u32, @intFromFloat(sy_float)), src_h - 1);
        const src_row_base = src_y * src_w * 4;
        sy_float += inv_scale_y;

        var dx: u32 = x0;
        var sx_float: f64 = @as(f64, @floatFromInt(sx0)) * inv_scale_x;
        while (dx < x1) : (dx += 1) {
            const src_x: u32 = @min(@as(u32, @intFromFloat(sx_float)), src_w - 1);
            sx_float += inv_scale_x;

            const src_idx = src_row_base + src_x * 4;
            const pr: u8 = rgba[src_idx + 0];
            const pg: u8 = rgba[src_idx + 1];
            const pb: u8 = rgba[src_idx + 2];
            const pa: u8 = rgba[src_idx + 3];

            if (pa == 0) continue;
            if (pa == 255) {
                putPixel32(dx, dy, @as(u32, pb) | (@as(u32, pg) << 8) | (@as(u32, pr) << 16));
            } else {
                blendPixel(dx, dy, @as(u32, pb) | (@as(u32, pg) << 8) | (@as(u32, pr) << 16), pa);
            }
        }
    }
}

/// Blit a RGBA bitmap to the framebuffer with explicit destination size (nearest-neighbor scaling).
/// @param rgba: pointer to RGBA pixel data (each pixel is 4 bytes: R, G, B, A in that order)
/// @param src_w: width of the source bitmap
/// @param src_h: height of the source bitmap
/// @param dest_x: X coordinate on screen (top-left corner)
/// @param dest_y: Y coordinate on screen (top-left corner)
/// @param dest_w: width on screen (after scaling)
/// @param dest_h: height on screen (after scaling)
pub fn blitRgbaScaled(
    rgba: [*]const u8,
    src_w: u32,
    src_h: u32,
    dest_x: i32,
    dest_y: i32,
    dest_w: i32,
    dest_h: i32,
) void {
    if (src_w == 0 or src_h == 0 or dest_w <= 0 or dest_h <= 0) return;

    // 处理负坐标裁剪
    const src_clip_x: u32 = if (dest_x < 0) @intCast(-dest_x) else 0;
    const src_clip_y: u32 = if (dest_y < 0) @intCast(-dest_y) else 0;
    const screen_x0: u32 = if (dest_x < 0) 0 else @intCast(dest_x);
    const screen_y0: u32 = if (dest_y < 0) 0 else @intCast(dest_y);

    if (screen_x0 >= fb_config.width or screen_y0 >= fb_config.height) return;

    const dw: u32 = @intCast(dest_w);
    const dh: u32 = @intCast(dest_h);

    const x1: u32 = @min(screen_x0 + dw, fb_config.width);
    const y1: u32 = @min(screen_y0 + dh, fb_config.height);
    if (screen_x0 >= x1 or screen_y0 >= y1) return;

    // 最近邻缩放：inverse scale = source pixels per destination pixel
    const inv_scale_x: f64 = @as(f64, @floatFromInt(src_w)) / @as(f64, @floatFromInt(dw));
    const inv_scale_y: f64 = @as(f64, @floatFromInt(src_h)) / @as(f64, @floatFromInt(dh));

    var dy: u32 = screen_y0;
    var sy_float: f64 = @as(f64, @floatFromInt(src_clip_y)) * inv_scale_y;
    while (dy < y1) : (dy += 1) {
        const src_y: u32 = @min(@as(u32, @intFromFloat(sy_float)), src_h - 1);
        const src_row_base = src_y * src_w * 4;
        sy_float += inv_scale_y;

        var dx: u32 = screen_x0;
        var sx_float: f64 = @as(f64, @floatFromInt(src_clip_x)) * inv_scale_x;
        while (dx < x1) : (dx += 1) {
            const src_x: u32 = @min(@as(u32, @intFromFloat(sx_float)), src_w - 1);
            sx_float += inv_scale_x;

            const src_idx = src_row_base + src_x * 4;
            const pa: u8 = rgba[src_idx + 3];
            if (pa == 0) continue;

            const pr: u8 = rgba[src_idx + 0];
            const pg: u8 = rgba[src_idx + 1];
            const pb: u8 = rgba[src_idx + 2];

            if (pa == 255) {
                putPixel32(dx, dy, @as(u32, pb) | (@as(u32, pg) << 8) | (@as(u32, pr) << 16));
            } else {
                blendPixel(dx, dy, @as(u32, pb) | (@as(u32, pg) << 8) | (@as(u32, pr) << 16), pa);
            }
        }
    }
}

// ── Optimized Drawing Primitives ──

fn fillRowDirect(py: u32, x0: u32, x1: u32, color: u32) void {
    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();
    const row_offset = pixelByteOffset(x0, py, bytes_pp);
    const count = x1 - x0;

    if (bytes_pp == 4) {
        const pxval = packPixel32(color);
        const base_addr = @intFromPtr(ptr) + row_offset;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const word_ptr: *align(1) volatile u32 = @ptrFromInt(base_addr + @as(usize, i) * 4);
            word_ptr.* = pxval;
        }
    } else if (bytes_pp == 3) {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            writePixel3(ptr, row_offset + @as(usize, i) * 3, color);
        }
    } else {
        var px: u32 = x0;
        while (px < x1) : (px += 1) {
            putPixel32(px, py, color);
        }
    }
}

pub fn fillRect(x: i32, y: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, @intCast(w), fb_config.width);
    const y1: u32 = addU32Clamped(y0, @intCast(h), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        fillRowDirect(py, x0, x1, color);
    }

    total_draw_calls += 1;
    addDirtyRect(.{ .x = x, .y = y, .w = w, .h = h });
}

/// 矩形区域拷贝：从 (src_x, src_y) 复制到 (dst_x, dst_y)
pub fn copyRect(src_x: i32, src_y: i32, dst_x: i32, dst_y: i32, w: i32, h: i32) void {
    if (w <= 0 or h <= 0) return;

    const bytes_pp: u32 = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();

    // 裁剪源区域
    const sx0: u32 = if (src_x < 0) 0 else @intCast(src_x);
    const sy0: u32 = if (src_y < 0) 0 else @intCast(src_y);
    const sx1: u32 = addU32Clamped(sx0, @intCast(w), fb_config.width);
    const sy1: u32 = addU32Clamped(sy0, @intCast(h), fb_config.height);
    if (sx0 >= sx1 or sy0 >= sy1) return;

    // 裁剪目标区域
    const dx0: u32 = if (dst_x < 0) 0 else @intCast(dst_x);
    const dy0: u32 = if (dst_y < 0) 0 else @intCast(dst_y);
    const copy_w = sx1 - sx0;
    const copy_h = sy1 - sy0;
    const dx1: u32 = addU32Clamped(dx0, copy_w, fb_config.width);
    const dy1: u32 = addU32Clamped(dy0, copy_h, fb_config.height);
    if (dx0 >= dx1 or dy0 >= dy1) return;

    const actual_w = @min(sx1 - sx0, dx1 - dx0);
    const actual_h = @min(sy1 - sy0, dy1 - dy0);
    if (actual_w == 0 or actual_h == 0) return;

    const row_bytes = @as(u32, actual_w) * bytes_pp;
    if (row_bytes == 0) return;

    // 确定拷贝方向：如果目标区域在源区域上方，需要从下往上拷贝以避免覆盖
    const forward_copy = (dst_y > src_y) or (dst_y == src_y and dst_x > src_x);

    // 使用更大的块复制优化：每个像素 4 字节时使用 usize 块
    const word_size: u32 = @sizeOf(usize);
    const words_per_row = row_bytes / word_size;
    const tail_bytes = row_bytes % word_size;

    if (forward_copy) {
        // 正向拷贝：从上往下
        var sy: u32 = sy0;
        var dy: u32 = dy0;
        while (sy < sy0 + actual_h) : ({
            sy += 1;
            dy += 1;
        }) {
            const src_row_base = pixelByteOffset(sx0, sy, bytes_pp);
            const dst_row_base = pixelByteOffset(dx0, dy, bytes_pp);

            // 块复制：按 usize 块（源和目标都是 volatile）
            var wi: u32 = 0;
            while (wi < words_per_row) : (wi += 1) {
                const off = wi * word_size;
                const src_off = src_row_base + off;
                const dst_off = dst_row_base + off;
                // 从源读取（volatile read）
                const w_val: usize = @as(*align(1) const usize, @ptrFromInt(@intFromPtr(ptr) + src_off)).*;
                // 写入目标（volatile write）
                @as(*align(1) volatile usize, @ptrFromInt(@intFromPtr(ptr) + dst_off)).* = w_val;
            }
            // 尾部字节复制
            var ti: u32 = 0;
            while (ti < tail_bytes) : (ti += 1) {
                ptr[dst_row_base + words_per_row * word_size + ti] = ptr[src_row_base + words_per_row * word_size + ti];
            }
        }
    } else {
        // 反向拷贝：从下往上
        var sy_i: i32 = @intCast(sy0 + actual_h - 1);
        var dy_i: i32 = @intCast(dy0 + actual_h - 1);
        while (sy_i >= @as(i32, @intCast(sy0))) : ({
            sy_i -= 1;
            dy_i -= 1;
        }) {
            const src_row_base = pixelByteOffset(sx0, @intCast(sy_i), bytes_pp);
            const dst_row_base = pixelByteOffset(dx0, @intCast(dy_i), bytes_pp);

            // 块复制：按 usize 块（源和目标都是 volatile）
            var wi: u32 = 0;
            while (wi < words_per_row) : (wi += 1) {
                const off = wi * word_size;
                const src_off = src_row_base + off;
                const dst_off = dst_row_base + off;
                // 从源读取（volatile read）
                const w_val: usize = @as(*align(1) const usize, @ptrFromInt(@intFromPtr(ptr) + src_off)).*;
                // 写入目标（volatile write）
                @as(*align(1) volatile usize, @ptrFromInt(@intFromPtr(ptr) + dst_off)).* = w_val;
            }
            // 尾部字节复制
            var ti: u32 = 0;
            while (ti < tail_bytes) : (ti += 1) {
                ptr[dst_row_base + words_per_row * word_size + ti] = ptr[src_row_base + words_per_row * word_size + ti];
            }
        }
    }

    total_draw_calls += 1;
    addDirtyRect(.{ .x = dst_x, .y = dst_y, .w = w, .h = h });
}

fn clampDrawCoordI64(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn clampRectSizeI64(v: i64) i32 {
    if (v <= 0) return 0;
    return @intCast(@min(v, @as(i64, std.math.maxInt(i32))));
}

pub fn drawRect(x: i32, y: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    drawHLine(x, y, w, color);
    drawHLine(x, clampDrawCoordI64(@as(i64, y) + @as(i64, h) - 1), w, color);
    drawVLine(x, y, h, color);
    drawVLine(clampDrawCoordI64(@as(i64, x) + @as(i64, w) - 1), y, h, color);
}

/// SDF 抗锯齿圆角矩形边框（Wu's algorithm 等效）
/// 使用符号距离场算法实现边缘平滑过渡
pub fn drawRoundedRectAA(x: i32, y: i32, w: i32, h: i32, radius: i32, color: u32) void {
    if (w <= 0 or h <= 0 or radius <= 0) return;
    const effective_r = @min(radius, @min(@divTrunc(w, 2), @divTrunc(h, 2)));
    if (effective_r <= 0) return;

    const r = effective_r;
    const aa_scale: f32 = 1.5;

    // 提取颜色分量
    const r_ch = (color >> 16) & 0xFF;
    const g_ch = (color >> 8) & 0xFF;
    const b_ch = color & 0xFF;

    // 绘制四条边（矩形部分，不包括圆角区域）
    const edge_x0 = x + r;
    const edge_w = w - 2 * r;
    const edge_h = h - 2 * r;

    // 上下边
    if (edge_w > 0) {
        drawHLine(edge_x0, y, edge_w, color);
        drawHLine(edge_x0, y + h - 1, edge_w, color);
    }
    // 左右边
    if (edge_h > 0) {
        drawVLine(x, y + r, edge_h, color);
        drawVLine(x + w - 1, y + r, edge_h, color);
    }

    // 绘制四个圆角弧（SDF 抗锯齿）
    // 四个角的位置：左上、右上、左下、右下
    const corners = [_]struct { cx: i32, cy: i32 }{
        .{ .cx = x + r, .cy = y + r },
        .{ .cx = x + w - r, .cy = y + r },
        .{ .cx = x + r, .cy = y + h - r },
        .{ .cx = x + w - r, .cy = y + h - r },
    };

    for (corners) |corner| {
        var dy: i32 = 0;
        while (dy <= r) : (dy += 1) {
            var dx: i32 = 0;
            while (dx <= r) : (dx += 1) {
                const cdx = @as(f32, @floatFromInt(dx));
                const cdy = @as(f32, @floatFromInt(dy));
                const dist_sq = cdx * cdx + cdy * cdy;
                const r_f = @as(f32, @floatFromInt(r));

                // 仅在边界附近绘制
                if (dist_sq > r_f * r_f + r_f * 2.0) continue;

                const dist = @sqrt(dist_sq);
                const edge_dist = @abs(dist - r_f);

                // 抗锯齿透明度计算
                var alpha: u8 = 255;
                if (edge_dist > 0) {
                    const t = @min(edge_dist / aa_scale, 1.0);
                    alpha = @intFromFloat(@round((1.0 - t) * 255.0));
                }

                if (alpha < 255) {
                    const px = corner.cx + dx;
                    const py = corner.cy + dy;

                    if (px >= 0 and px < @as(i32, @intCast(fb_config.width)) and
                        py >= 0 and py < @as(i32, @intCast(fb_config.height))) {
                        const existing = getPixel32(@as(u32, @intCast(px)), @as(u32, @intCast(py)));
                        const er = (existing >> 16) & 0xFF;
                        const eg = (existing >> 8) & 0xFF;
                        const eb = existing & 0xFF;

                        const inv_alpha: u32 = 255 - @as(u32, alpha);
                        const out_r = (@as(u32, r_ch) * @as(u32, alpha) + @as(u32, er) * inv_alpha) / 255;
                        const out_g = (@as(u32, g_ch) * @as(u32, alpha) + @as(u32, eg) * inv_alpha) / 255;
                        const out_b = (@as(u32, b_ch) * @as(u32, alpha) + @as(u32, eb) * inv_alpha) / 255;

                        putPixel32(@as(u32, @intCast(px)), @as(u32, @intCast(py)),
                            (out_r << 16) | (out_g << 8) | out_b);
                    }
                }
            }
        }
    }
}

/// Wu's anti-aliased line algorithm（抗锯齿线段）
pub fn drawLineAA(x1: i32, y1: i32, x2: i32, y2: i32, color: u32) void {
    const dx: u32 = @intCast(@abs(x2 - x1));
    const dy: u32 = @intCast(@abs(y2 - y1));

    const r_ch: u8 = @intCast((color >> 16) & 0xFF);
    const g_ch: u8 = @intCast((color >> 8) & 0xFF);
    const b_ch: u8 = @intCast(color & 0xFF);

    const sx: i32 = if (x1 < x2) 1 else -1;
    const sy: i32 = if (y1 < y2) 1 else -1;
    var err: i32 = @as(i32, @intCast(dx)) -| @as(i32, @intCast(dy));

    var x = x1;
    var y = y1;

    while (true) {
        // 绘制主像素
        if (x >= 0 and x < @as(i32, @intCast(fb_config.width)) and
            y >= 0 and y < @as(i32, @intCast(fb_config.height))) {
            const existing = getPixel32(@as(u32, @intCast(x)), @as(u32, @intCast(y)));
            blendPixelWithAA(@as(u32, @intCast(x)), @as(u32, @intCast(y)), r_ch, g_ch, b_ch, @as(u8, 255), existing);
        }

        if (x == x2 and y == y2) break;

        // 计算误差并更新像素位置
        const e2: i32 = err * 2;
        const dy_i: i32 = @as(i32, @intCast(dy));
        const dx_i: i32 = @as(i32, @intCast(dx));
        if (e2 > -dy_i) {
            err -= dy_i;
            x += sx;
        }
        if (e2 < dx_i) {
            err += dx_i;
            y += sy;
        }
    }
}

/// 基于 alpha 混合像素
fn blendPixelWithAA(px: u32, py: u32, r_ch: u8, g_ch: u8, b_ch: u8, alpha: u8, existing: u32) void {
    if (alpha >= 255) {
        putPixel32(px, py, (@as(u32, r_ch) << 16) | (@as(u32, g_ch) << 8) | @as(u32, b_ch));
        return;
    }
    if (alpha == 0) return;

    const er = (existing >> 16) & 0xFF;
    const eg = (existing >> 8) & 0xFF;
    const eb = existing & 0xFF;

    const inv_alpha: u32 = 255 - @as(u32, alpha);
    const out_r = (@as(u32, r_ch) * @as(u32, alpha) + @as(u32, er) * inv_alpha) / 255;
    const out_g = (@as(u32, g_ch) * @as(u32, alpha) + @as(u32, eg) * inv_alpha) / 255;
    const out_b = (@as(u32, b_ch) * @as(u32, alpha) + @as(u32, eb) * inv_alpha) / 255;

    putPixel32(px, py, (out_r << 16) | (out_g << 8) | out_b);
}

pub fn drawHLine(x: i32, y: i32, length: i32, color: u32) void {
    if (length <= 0 or y < 0 or y >= @as(i32, @intCast(fb_config.height))) return;
    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const x1: u32 = addU32Clamped(x0, @intCast(length), fb_config.width);
    if (x0 >= x1) return;
    fillRowDirect(@intCast(y), x0, x1, color);
}

pub fn drawVLine(x: i32, y: i32, length: i32, color: u32) void {
    if (length <= 0 or x < 0 or x >= @as(i32, @intCast(fb_config.width))) return;
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const y1: u32 = addU32Clamped(y0, @intCast(length), fb_config.height);
    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        putPixel32(@intCast(x), py, color);
    }
}

pub fn drawGradientH(x: i32, y: i32, w: i32, h: i32, color1: u32, color2: u32) void {
    if (w <= 0 or h <= 0) return;
    const uw: u32 = @intCast(w);
    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, uw, fb_config.width);
    const y1: u32 = addU32Clamped(y0, @intCast(h), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();
    const row_pixels = x1 - x0;
    const base_x: u32 = if (x < 0) 0 else @intCast(x);

    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        const row_offset = pixelByteOffset(x0, py, bytes_pp);
        var px: u32 = 0;
        while (px < row_pixels) : (px += 1) {
            const t = (x0 + px) -| base_x;
            const color = interpolateColor(color1, color2, t, uw);
            if (bytes_pp == 4) {
                writePixel4(ptr, row_offset + @as(usize, px) * 4, color);
            } else if (bytes_pp == 3) {
                writePixel3(ptr, row_offset + @as(usize, px) * 3, color);
            } else {
                putPixel32(x0 + px, py, color);
            }
        }
    }
    total_draw_calls += 1;
    addDirtyRect(.{ .x = x, .y = y, .w = w, .h = h });
}

pub fn drawGradientV(x: i32, y: i32, w: i32, h: i32, color1: u32, color2: u32) void {
    if (w <= 0 or h <= 0) return;
    const uh: u32 = @intCast(h);
    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, @intCast(w), fb_config.width);
    const y1: u32 = addU32Clamped(y0, uh, fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const base_y: u32 = if (y < 0) 0 else @intCast(y);
    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        const t = py -| base_y;
        const color = interpolateColor(color1, color2, t, uh);
        fillRowDirect(py, x0, x1, color);
    }
    total_draw_calls += 1;
    addDirtyRect(.{ .x = x, .y = y, .w = w, .h = h });
}

pub fn interpolateColor(c1: u32, c2: u32, t: u32, total: u32) u32 {
    if (total == 0) return c1;
    const r1 = c1 & 0xFF;
    const g1 = (c1 >> 8) & 0xFF;
    const b1 = (c1 >> 16) & 0xFF;
    const r2 = c2 & 0xFF;
    const g2 = (c2 >> 8) & 0xFF;
    const b2 = (c2 >> 16) & 0xFF;

    const r = blendChannel(r1, r2, t, total);
    const g = blendChannel(g1, g2, t, total);
    const b = blendChannel(b1, b2, t, total);

    return (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16);
}

fn blendChannel(a: u32, b: u32, t: u32, total: u32) u32 {
    if (b >= a) {
        const da: u64 = b - a;
        const delta: u64 = da * @as(u64, t) / @as(u64, total);
        const sum = @as(u64, a) + delta;
        return @as(u32, @intCast(@min(sum, @as(u64, 255))));
    } else {
        const da: u64 = a - b;
        const delta: u64 = da * @as(u64, t) / @as(u64, total);
        const sub: u64 = @min(delta, @as(u64, 255));
        const v = @as(i64, @intCast(@min(a, 255))) - @as(i64, @intCast(sub));
        return @as(u32, @intCast(@min(255, @max(0, v))));
    }
}

pub fn clearScreen(color: u32) void {
    if (fb_config.width == 0 or fb_config.height == 0) return;
    const bytes_pp = @as(u32, fb_config.bpp) / 8;

    if (bytes_pp == 4) {
        const pxval = packPixel32(color);
        const ptr = getDrawBuffer();
        const base_addr = @intFromPtr(ptr);
        const total: usize = @intCast(@as(u64, fb_config.pitch) * @as(u64, fb_config.height));
        var off: usize = 0;
        while (off < total) : (off += 4) {
            const word_ptr: *align(1) volatile u32 = @ptrFromInt(base_addr + off);
            word_ptr.* = pxval;
        }
        total_draw_calls += 1;
    } else {
        fillRect(0, 0, @intCast(fb_config.width), @intCast(fb_config.height), color);
    }
}

// ── Text Rendering (8x16 bitmap font) ──

/// 默认字体尺寸
const CHAR_W: u32 = 8;
const CHAR_H: u32 = 16;

/// 字体缩放因子（支持 DPI 缩放）
var font_scale: u32 = 1;

/// 缩放后的字体尺寸（派生值）
fn scaledCharW() u32 {
    return CHAR_W * font_scale;
}
fn scaledCharH() u32 {
    return CHAR_H * font_scale;
}

/// 字体配置结构
pub const FontConfig = struct {
    scale: u32 = 1,
};

var font_cfg: FontConfig = .{};

/// 配置字体缩放（用于高 DPI 屏幕）
pub fn configureFont(cfg: FontConfig) void {
    font_cfg = cfg;
    font_scale = if (cfg.scale == 0) 1 else cfg.scale;
}

/// 获取当前字体配置
pub fn getFontConfig() FontConfig {
    return font_cfg;
}

/// 获取当前字体缩放因子
pub fn getFontScale() u32 {
    return font_scale;
}

pub fn drawChar(x: i32, y: i32, ch: u8, fg: u32, bg: u32) void {
    const glyph = getGlyph(ch);
    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();
    const sw = scaledCharW();
    const sh = scaledCharH();

    var dy: u32 = 0;
    while (dy < sh) : (dy += 1) {
        const row_idx = @divTrunc(dy, font_scale);
        const py = if (y < 0) return else @as(u32, @intCast(y)) + dy;
        if (py >= fb_config.height) break;
        const bits = glyph[row_idx];

        var dx: u32 = 0;
        while (dx < sw) : (dx += 1) {
            const bit_idx = @divTrunc(dx, font_scale);
            const px = if (x < 0) continue else @as(u32, @intCast(x)) + dx;
            if (px >= fb_config.width) break;
            const on = (bits >> @intCast(7 - bit_idx)) & 1;
            const color: u32 = if (on != 0) fg else bg;
            const off = pixelByteOffset(px, py, bytes_pp);
            if (bytes_pp == 4) {
                writePixel4(ptr, off, color);
            } else if (bytes_pp == 3) {
                writePixel3(ptr, off, color);
            }
        }
    }
}

pub fn drawCharTransparent(x: i32, y: i32, ch: u8, fg: u32) void {
    const glyph = getGlyph(ch);
    const fw: i64 = @intCast(fb_config.width);
    const fh: i64 = @intCast(fb_config.height);
    const sw = scaledCharW();
    const sh = scaledCharH();

    var dy: u32 = 0;
    while (dy < sh) : (dy += 1) {
        const row_idx = @divTrunc(dy, font_scale);
        const py_i = @as(i64, y) + @as(i64, dy);
        if (py_i < 0 or py_i >= fh) continue;
        const bits = glyph[row_idx];

        var dx: u32 = 0;
        while (dx < sw) : (dx += 1) {
            const bit_idx = @divTrunc(dx, font_scale);
            if ((bits >> @intCast(7 - bit_idx)) & 1 != 0) {
                const px_i = @as(i64, x) + @as(i64, dx);
                if (px_i >= 0 and px_i < fw) {
                    putPixel32(@intCast(px_i), @intCast(py_i), fg);
                }
            }
        }
    }
}

fn drawCjk16Transparent(x: i32, y: i32, rows: [16]u16, fg: u32) void {
    const fw: i64 = @intCast(fb_config.width);
    const fh: i64 = @intCast(fb_config.height);
    var dy: u32 = 0;
    while (dy < cjk_font.CJK_H) : (dy += 1) {
        const py_i = @as(i64, y) + @as(i64, dy);
        if (py_i < 0 or py_i >= fh) continue;
        const bits = rows[dy];
        var dx: u32 = 0;
        while (dx < cjk_font.CJK_W) : (dx += 1) {
            if ((bits >> @intCast(15 - dx)) & 1 != 0) {
                const px_i = @as(i64, x) + @as(i64, dx);
                if (px_i >= 0 and px_i < fw) {
                    putPixel32(@intCast(px_i), @intCast(py_i), fg);
                }
            }
        }
    }
}

fn drawTextTransparentClippedInner(x: i32, y: i32, text: []const u8, fg: u32, clip_max_x: ?i32) void {
    const cw_i64 = @as(i64, @intCast(scaledCharW()));
    const view = std.unicode.Utf8View.init(text) catch {
        var cx64 = @as(i64, x);
        for (text) |b| {
            if (clip_max_x) |mx| {
                if (cx64 + cw_i64 > @as(i64, mx)) break;
            }
            const cx_clamped = std.math.clamp(cx64, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32)));
            const cxi: i32 = @intCast(cx_clamped);
            drawCharTransparent(cxi, y, b, fg);
            cx64 += cw_i64;
        }
        return;
    };
    var it = view.iterator();
    var cx64 = @as(i64, x);
    while (it.nextCodepoint()) |cp| {
        const adv64 = @as(i64, @intCast(cjk_font.codepointWidth(cp)));
        if (clip_max_x) |mx| {
            if (cx64 + adv64 > @as(i64, mx)) break;
        }
        const cx_clamped = std.math.clamp(cx64, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32)));
        const cxi: i32 = @intCast(cx_clamped);
        if (cp < 0x80) {
            drawCharTransparent(cxi, y, @truncate(cp), fg);
        } else if (cjk_font.lookup(cp)) |rows| {
            drawCjk16Transparent(cxi, y, rows, fg);
        } else if (cjk_font.isWideCodepoint(cp)) {
            drawCjk16Transparent(cxi, y, cjk_font.tofu_rows, fg);
        } else {
            drawCharTransparent(cxi, y, '?', fg);
        }
        cx64 += adv64;
    }
}

/// 在 [x, x_max_excl) 内绘制 UTF-8 文本，超出右边界则截断。
pub fn drawTextTransparentClipped(x: i32, y: i32, x_max_excl: i32, text: []const u8, fg: u32) void {
    drawTextTransparentClippedInner(x, y, text, fg, x_max_excl);
}

pub fn drawText(x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
    const fw: i64 = @intCast(fb_config.width);
    const cw_i64 = @as(i64, @intCast(scaledCharW()));
    var cx64 = @as(i64, x);
    for (text) |ch| {
        if (cx64 + cw_i64 > fw) break;
        const cxi = clampDrawCoordI64(cx64);
        drawChar(cxi, y, ch, fg, bg);
        cx64 += cw_i64;
    }
}

pub fn drawTextTransparent(x: i32, y: i32, text: []const u8, fg: u32) void {
    drawTextTransparentClippedInner(x, y, text, fg, @intCast(fb_config.width));
}

/// Aero / Win7 风格 UI 文本：轻微投影，减轻纯 8×16 点阵「固件控制台」观感（内核自绘，与 UEFI ConOut 无关）。
pub fn drawTextTransparentUi(x: i32, y: i32, text: []const u8, fg: u32) void {
    const r = @as(u32, getRed(fg)) * 12 / 40;
    const g = @as(u32, getGreen(fg)) * 12 / 40;
    const b = @as(u32, getBlue(fg)) * 12 / 40;
    const shadow = (r << 16) | (g << 8) | b;
    drawTextTransparent(clampDrawCoordI64(@as(i64, x) + 1), clampDrawCoordI64(@as(i64, y) + 1), text, shadow);
    drawTextTransparent(x, y, text, fg);
}

/// `drawTextTransparentUi` 在矩形内水平垂直居中（字宽与 `textWidth` / UTF-8 路径一致）。
pub fn drawTextTransparentUiCenteredInRect(rx: i32, ry: i32, rw: i32, rh: i32, text: []const u8, fg: u32) void {
    if (rw <= 0 or rh <= 0) return;
    const tw = textWidth(text);
    var tx = rx + @divTrunc(rw - tw, 2);
    if (tx < rx) tx = rx;
    const ty = ry + @divTrunc(rh - @as(i32, CHAR_H), 2);
    drawTextTransparentUi(tx, ty, text, fg);
}

/// 2× / 3× scaled glyphs for taskbar and status lines (clearer than 8×16 on large panels).
pub fn drawCharTransparentScaled(x: i32, y: i32, ch: u8, fg: u32, scale: u32) void {
    if (scale < 1) return;
    const sw: i32 = std.math.cast(i32, scale) orelse return;
    const glyph = getGlyph(ch);
    const sc_i = @as(i64, scale);
    var dy: u32 = 0;
    while (dy < CHAR_H) : (dy += 1) {
        const bits = glyph[dy];
        var dx: u32 = 0;
        while (dx < CHAR_W) : (dx += 1) {
            if ((bits >> @intCast(7 - dx)) & 1 != 0) {
                const px0 = @as(i64, x) + @as(i64, dx) * sc_i;
                const py0 = @as(i64, y) + @as(i64, dy) * sc_i;
                fillRect(clampDrawCoordI64(px0), clampDrawCoordI64(py0), sw, sw, fg);
            }
        }
    }
}

pub fn drawTextTransparentScaled(x: i32, y: i32, text: []const u8, fg: u32, scale: u32) void {
    if (scale < 1) return;
    var cx64 = @as(i64, x);
    const adv: i64 = @as(i64, CHAR_W) * @as(i64, scale);
    const fb_w_i64: i64 = @intCast(fb_config.width);
    for (text) |ch| {
        if (cx64 + adv > fb_w_i64) break;
        drawCharTransparentScaled(clampDrawCoordI64(cx64), y, ch, fg, scale);
        cx64 += adv;
    }
}

pub fn textWidthScaled(text: []const u8, scale: u32) i32 {
    if (scale < 1) return 0;
    const prod = @as(u128, text.len) *% @as(u128, CHAR_W) *% @as(u128, scale);
    const capped = @min(prod, @as(u128, std.math.maxInt(i32)));
    return @as(i32, @intCast(capped));
}

pub fn drawTextCentered(x: i32, y: i32, w: i32, h: i32, text: []const u8, fg: u32) void {
    const text_w: i32 = textWidth(text);
    const tx = x + @divTrunc(w - text_w, 2);
    const ty = y + @divTrunc(h - @as(i32, @intCast(scaledCharH())), 2);
    drawTextTransparent(tx, ty, text, fg);
}

pub fn textWidth(text: []const u8) i32 {
    const view = std.unicode.Utf8View.init(text) catch {
        const prod = @as(u128, text.len) *% @as(u128, CHAR_W);
        const capped = @min(prod, @as(u128, std.math.maxInt(i32)));
        return @as(i32, @intCast(capped));
    };
    var it = view.iterator();
    var w64: i64 = 0;
    while (it.nextCodepoint()) |cp| {
        w64 += @as(i64, @intCast(cjk_font.codepointWidth(cp)));
        if (w64 > std.math.maxInt(i32)) return std.math.maxInt(i32);
    }
    const w_clamped = std.math.clamp(w64, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32)));
    return @as(i32, @intCast(w_clamped));
}

// ── Rounded Rectangle ──

pub fn fillRoundedRect(x: i32, y: i32, w: i32, h: i32, radius: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    const r = @min(radius, @min(@divTrunc(w, 2), @divTrunc(h, 2)));
    const x64 = @as(i64, x);
    const y64 = @as(i64, y);
    const w64 = @as(i64, w);
    const h64 = @as(i64, h);
    const rr = @as(i64, r);

    fillRect(clampDrawCoordI64(x64 + rr), y, clampRectSizeI64(w64 - 2 * rr), r, color);
    fillRect(x, clampDrawCoordI64(y64 + rr), w, clampRectSizeI64(h64 - 2 * rr), color);
    fillRect(clampDrawCoordI64(x64 + rr), clampDrawCoordI64(y64 + h64 - rr), clampRectSizeI64(w64 - 2 * rr), r, color);

    fillCircleQuarter(clampDrawCoordI64(x64 + rr), clampDrawCoordI64(y64 + rr), r, 0, color);
    fillCircleQuarter(clampDrawCoordI64(x64 + w64 - rr - 1), clampDrawCoordI64(y64 + rr), r, 1, color);
    fillCircleQuarter(clampDrawCoordI64(x64 + rr), clampDrawCoordI64(y64 + h64 - rr - 1), r, 2, color);
    fillCircleQuarter(clampDrawCoordI64(x64 + w64 - rr - 1), clampDrawCoordI64(y64 + h64 - rr - 1), r, 3, color);
}

fn fillCircleQuarter(cx: i32, cy: i32, radius: i32, quarter: u2, color: u32) void {
    if (radius <= 0) return;
    const cx64 = @as(i64, cx);
    const cy64 = @as(i64, cy);
    const r64 = @as(i64, radius);
    const r2 = r64 * r64;
    const fw = @as(i64, fb_config.width);
    const fh = @as(i64, fb_config.height);
    var dy: i32 = 0;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = 0;
        while (dx <= radius) : (dx += 1) {
            const dx64 = @as(i64, dx);
            const dy64 = @as(i64, dy);
            if (dx64 * dx64 + dy64 * dy64 <= r2) {
                const px64: i64 = switch (quarter) {
                    0 => cx64 - dx64,
                    1 => cx64 + dx64,
                    2 => cx64 - dx64,
                    3 => cx64 + dx64,
                };
                const py64: i64 = switch (quarter) {
                    0 => cy64 - dy64,
                    1 => cy64 - dy64,
                    2 => cy64 + dy64,
                    3 => cy64 + dy64,
                };
                if (px64 >= 0 and py64 >= 0 and px64 < fw and py64 < fh) {
                    putPixel32(@intCast(px64), @intCast(py64), color);
                }
            }
        }
    }
}

/// Filled circle centered at `(cx, cy)` with integer radius (bounding box `2r×2r`).
pub fn fillCircle(cx: i32, cy: i32, radius: i32, color: u32) void {
    if (radius <= 0) return;
    const d = clampRectSizeI64(@as(i64, radius) * 2);
    fillRoundedRect(
        clampDrawCoordI64(@as(i64, cx) - @as(i64, radius)),
        clampDrawCoordI64(@as(i64, cy) - @as(i64, radius)),
        d,
        d,
        radius,
        color,
    );
}

/// Aero-style orb sheen: blend `sheen_rgb` toward the top and upper-left inside the disk.
/// Ref: public Win7 Aero orb appearance (gloss + sphere read); clean-room pixel recipe.
pub fn aeroSheenDisk(cx: i32, cy: i32, radius: i32, sheen_rgb: u32) void {
    if (radius <= 0) return;
    const cx64 = @as(i64, cx);
    const cy64 = @as(i64, cy);
    const r64 = @as(i64, radius);
    const r2 = r64 * r64;
    const top = cy64 - r64;
    const span: i32 = @max(1, clampRectSizeI64(r64 * 2));

    var py64 = cy64 - r64;
    while (py64 <= cy64 + r64) : (py64 += 1) {
        const dy64 = py64 - cy64;
        const from_top: i32 = clampDrawCoordI64(py64 - top);
        // `from_top * 95` 在 i32 上 Debug 可能溢出（clamp 后仍可达 INT_MAX）；用 i64 归一化。
        const span64 = @as(i64, span);
        const base_num = @as(i64, from_top) * 95;
        const base_div = @divTrunc(base_num, span64);
        const base_a: u32 = @intCast(@min(@as(i64, 95), @max(@as(i64, 0), base_div)));
        if (base_a == 0) continue;

        var px64 = cx64 - r64;
        while (px64 <= cx64 + r64) : (px64 += 1) {
            const dx64 = px64 - cx64;
            if (dx64 * dx64 + dy64 * dy64 > r2) continue;
            if (px64 < 0 or py64 < 0) continue;
            const ux: u32 = @intCast(px64);
            const uy: u32 = @intCast(py64);
            if (ux >= fb_config.width or uy >= fb_config.height) continue;

            var a: u32 = base_a;
            const px_i = clampDrawCoordI64(px64);
            const py_i = clampDrawCoordI64(py64);
            const cx_i = clampDrawCoordI64(cx64);
            const cy_i = clampDrawCoordI64(cy64);
            const cy_hi = @as(i64, cy_i) + @divTrunc(@as(i64, radius), 4);
            if (px_i <= cx_i and @as(i64, py_i) <= cy_hi) {
                a +|= 42;
            }
            if (a > 155) a = 155;
            blendPixel(ux, uy, sheen_rgb, @intCast(a));
        }
    }
    markDirtyRegion(
        clampDrawCoordI64(cx64 - r64),
        clampDrawCoordI64(cy64 - r64),
        clampRectSizeI64(r64 * 2 + 1),
        clampRectSizeI64(r64 * 2 + 1),
    );
}

// ── 3D-style border effects ──

pub fn draw3DRect(x: i32, y: i32, w: i32, h: i32, highlight: u32, shadow: u32) void {
    if (w <= 0 or h <= 0) return;
    drawHLine(x, y, w, highlight);
    drawVLine(x, y, h, highlight);
    drawHLine(x, clampDrawCoordI64(@as(i64, y) + @as(i64, h) - 1), w, shadow);
    drawVLine(clampDrawCoordI64(@as(i64, x) + @as(i64, w) - 1), y, h, shadow);
}

// ── Aero Glass Blur (Multi-pass Box Blur) ──
// Three passes of separable box blur approximate a Gaussian blur.
// Operates directly on the framebuffer using a static line buffer.
// 每像素内层循环随 radius 增长；中长期可改滑动窗口累和或降采样 blur 再上采样（自研，见 DesktopManagerSpec §8）。

const BLUR_MAX_LINE: usize = 4096;
var blur_line: [BLUR_MAX_LINE]u32 = [_]u32{0} ** BLUR_MAX_LINE;
/// 水平 pass 临时结果缓冲区（避免同缓冲区读写导致垂直 pass 基于错误数据计算）。
var blur_line_h: [BLUR_MAX_LINE]u32 = [_]u32{0} ** BLUR_MAX_LINE;

// ── Blur Performance Configuration ──

/// 小于此面积（像素数）的区域直接跳过模糊（避免过度计算）
const BLUR_MIN_AREA_PIXELS: u32 = 64 * 64;

/// 下采样阈值：宽或高超过此值时启用下采样模糊
const BLUR_DOWNSCALE_THRESHOLD: u32 = 512;

/// 下采样比例（2=缩小一半）
const BLUR_DOWNSCALE_FACTOR: u32 = 2;

/// 最小可模糊面积（避免死循环或极小区域开销不成比例）
const BLUR_MIN_DIMENSION: u32 = 8;

// ── Blur Efficiency Helper ──

/// 判断给定矩形是否应该跳过模糊处理（面积太小不值得模糊）
fn shouldSkipBlur(w: u32, h: u32) bool {
    return w < BLUR_MIN_DIMENSION or h < BLUR_MIN_DIMENSION or
        w * h < BLUR_MIN_AREA_PIXELS;
}

/// 检查是否应该使用下采样模糊
fn shouldUseDownscaledBlur(w: u32, h: u32) bool {
    return w > BLUR_DOWNSCALE_THRESHOLD or h > BLUR_DOWNSCALE_THRESHOLD;
}

/// 优化的模糊矩形处理：
/// 1. 小区域早退出（面积 < 64×64 直接跳过）
/// 2. 大区域下采样（>512px 边长时缩小后模糊再放大）
pub fn boxBlurRect(x: i32, y: i32, w: i32, h: i32, radius: u32, passes: u32) void {
    if (w <= 0 or h <= 0 or radius == 0 or passes == 0) return;
    if (!config_ready) return;
    if (fb_config.bpp < 24) return;

    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, @intCast(w), fb_config.width);
    const y1: u32 = addU32Clamped(y0, @intCast(h), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const rw = x1 - x0;
    const rh = y1 - y0;

    // 早退出：小区域不值得模糊
    if (shouldSkipBlur(rw, rh)) return;

    // 边界检查
    if (rw > BLUR_MAX_LINE or rh > BLUR_MAX_LINE) return;

    // 大区域使用下采样优化
    if (shouldUseDownscaledBlur(rw, rh)) {
        boxBlurRectDownscaled(x0, y0, rw, rh, radius, passes);
        return;
    }

    boxBlurRectCore(x0, y0, rw, rh, radius, passes);
}

/// 下采样模糊：缩小→模糊→放大
fn boxBlurRectDownscaled(x0: u32, y0: u32, w: u32, h: u32, radius: u32, passes: u32) void {
    const factor = BLUR_DOWNSCALE_FACTOR;
    const sw = @max(w / factor, 1);
    const sh = @max(h / factor, 1);
    const sr = @max(radius / factor, 1);
    // 精确分配下采样图像尺寸（w×h 的 1/factor²），避免使用静态 [4096]u32 缓冲区
    // 导致上采样插值阶段索引越界（sw*sh 在大屏（如 1440×900）下可达 202500）。
    const small_len = @as(usize, sw) * @as(usize, sh);
    var small_buf: []u32 = @import("../../../mm/heap.zig").allocSlice(u32, small_len) orelse return;
    var small_tmp: []u32 = @import("../../../mm/heap.zig").allocSlice(u32, small_len) orelse return;

    const buf = getDrawBuffer();
    const pitch = fb_config.pitch;
    const bpp: u32 = @as(u32, fb_config.bpp) / 8;

    var pass: u32 = 0;
    while (pass < passes) : (pass += 1) {
        // 下采样阶段：每 2×2 区块合并为 1 个像素
        var sy: u32 = 0;
        while (sy < sh) : (sy += 1) {
            const src_y0 = y0 + sy * factor;
            const src_y1 = @min(src_y0 + factor, y0 + h);
            var sx: u32 = 0;
            while (sx < sw) : (sx += 1) {
                const src_x0 = x0 + sx * factor;
                var sr_sum: u64 = 0;
                var sg_sum: u64 = 0;
                var sb_sum: u64 = 0;
                var cnt: u64 = 0;
                var cy: u32 = src_y0;
                while (cy < src_y1) : (cy += 1) {
                    var cx: u32 = src_x0;
                    while (cx < @min(src_x0 + factor, x0 + w)) : (cx += 1) {
                        const off = cy * pitch + cx * bpp;
                        sr_sum += buf[off + 2];
                        sg_sum += buf[off + 1];
                        sb_sum += buf[off];
                        cnt += 1;
                    }
                }
                if (cnt > 0) {
                    small_buf[sx] = (@as(u32, @truncate(sr_sum / cnt)) << 16) |
                        (@as(u32, @truncate(sg_sum / cnt)) << 8) |
                        @as(u32, @truncate(sb_sum / cnt));
                }
            }
            // 对下采样行执行一维水平模糊
            blurRow1DPacked(small_buf[0..sw], small_tmp[0..sw], sr, sw);
            @memcpy(small_buf[0..sw], small_tmp[0..sw]);
        }

        // 垂直方向模糊（下采样空间）
        var sx2: u32 = 0;
        while (sx2 < sw) : (sx2 += 1) {
            blurCol1DPacked(small_buf[0..sh], small_tmp[0..sh], sr, sh);
            @memcpy(small_buf[0..sh], small_tmp[0..sh]);
        }

        // 上采样阶段：将模糊后的像素写回原区域，使用双线性插值提升质量
        var sy2: u32 = 0;
        while (sy2 < sh) : (sy2 += 1) {
            const dst_y0 = y0 + sy2 * factor;
            const dst_y1 = @min(dst_y0 + factor, y0 + h);
            var sx2b: u32 = 0;
            while (sx2b < sw) : (sx2b += 1) {
                // 双线性插值：采样周围 2×2 像素进行混合
                const tl = small_buf[sy2 * sw + sx2b];
                const tr: u32 = if (sx2b + 1 < sw) small_buf[sy2 * sw + sx2b + 1] else tl;
                const bl: u32 = if (sy2 + 1 < sh) small_buf[(sy2 + 1) * sw + sx2b] else tl;
                const br: u32 = if (sx2b + 1 < sw and sy2 + 1 < sh)
                    small_buf[(sy2 + 1) * sw + sx2b + 1]
                else if (sx2b + 1 < sw) tr
                else if (sy2 + 1 < sh) bl
                else tl;

                const dst_x0 = x0 + sx2b * factor;
                const dst_x1 = @min(dst_x0 + factor, x0 + w);

                // 对每个目标像素计算双线性权重
                var cy: u32 = dst_y0;
                while (cy < dst_y1) : (cy += 1) {
                    var cx: u32 = dst_x0;
                    while (cx < dst_x1) : (cx += 1) {
                        // 计算相对于小块边界的分数偏移
                        const fx = @as(f32, @floatFromInt(cx - dst_x0)) / @as(f32, @floatFromInt(factor));
                        const fy = @as(f32, @floatFromInt(cy - dst_y0)) / @as(f32, @floatFromInt(factor));

                        // 提取四角的 RGB 分量
                        const tl_r: u32 = (tl >> 16) & 0xFF;
                        const tl_g: u32 = (tl >> 8) & 0xFF;
                        const tl_b: u32 = tl & 0xFF;
                        const tr_r: u32 = (tr >> 16) & 0xFF;
                        const tr_g: u32 = (tr >> 8) & 0xFF;
                        const tr_b: u32 = tr & 0xFF;
                        const bl_r: u32 = (bl >> 16) & 0xFF;
                        const bl_g: u32 = (bl >> 8) & 0xFF;
                        const bl_b: u32 = bl & 0xFF;
                        const br_r: u32 = (br >> 16) & 0xFF;
                        const br_g: u32 = (br >> 8) & 0xFF;
                        const br_b: u32 = br & 0xFF;

                        // 双线性插值
                        const r = (@as(f32, @floatFromInt(tl_r)) * (1.0 - fx) * (1.0 - fy) +
                            @as(f32, @floatFromInt(tr_r)) * fx * (1.0 - fy) +
                            @as(f32, @floatFromInt(bl_r)) * (1.0 - fx) * fy +
                            @as(f32, @floatFromInt(br_r)) * fx * fy);
                        const g = (@as(f32, @floatFromInt(tl_g)) * (1.0 - fx) * (1.0 - fy) +
                            @as(f32, @floatFromInt(tr_g)) * fx * (1.0 - fy) +
                            @as(f32, @floatFromInt(bl_g)) * (1.0 - fx) * fy +
                            @as(f32, @floatFromInt(br_g)) * fx * fy);
                        const b = (@as(f32, @floatFromInt(tl_b)) * (1.0 - fx) * (1.0 - fy) +
                            @as(f32, @floatFromInt(tr_b)) * fx * (1.0 - fy) +
                            @as(f32, @floatFromInt(bl_b)) * (1.0 - fx) * fy +
                            @as(f32, @floatFromInt(br_b)) * fx * fy);

                        const off = cy * pitch + cx * bpp;
                        buf[off + 2] = @as(u8, @intFromFloat(r));
                        buf[off + 1] = @as(u8, @intFromFloat(g));
                        buf[off] = @as(u8, @intFromFloat(b));
                    }
                }
            }
        }
    }
    total_draw_calls += 1;
}

/// 一维水平模糊（原地，src → dst，处理 RGBXRGBXRGBX 格式）
fn blurRow1DPacked(src: []u32, dst: []u32, radius: u32, len: u32) void {
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const lo: u32 = if (i >= radius) i - radius else 0;
        const hi: u32 = @min(i + radius + 1, len);
        const cnt = hi - lo;
        var sr: u64 = 0;
        var sg: u64 = 0;
        var sb: u64 = 0;
        var j: u32 = lo;
        while (j < hi) : (j += 1) {
            const p = src[j];
            sr += (p >> 16) & 0xFF;
            sg += (p >> 8) & 0xFF;
            sb += p & 0xFF;
        }
        dst[i] = (@as(u32, @truncate(sr / cnt)) << 16) |
            (@as(u32, @truncate(sg / cnt)) << 8) |
            @as(u32, @truncate(sb / cnt));
    }
}

/// 一维垂直模糊（原地，src → dst）
fn blurCol1DPacked(src: []u32, dst: []u32, radius: u32, len: u32) void {
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const lo: u32 = if (i >= radius) i - radius else 0;
        const hi: u32 = @min(i + radius + 1, len);
        const cnt = hi - lo;
        var sr: u64 = 0;
        var sg: u64 = 0;
        var sb: u64 = 0;
        var j: u32 = lo;
        while (j < hi) : (j += 1) {
            const p = src[j];
            sr += (p >> 16) & 0xFF;
            sg += (p >> 8) & 0xFF;
            sb += p & 0xFF;
        }
        dst[i] = (@as(u32, @truncate(sr / cnt)) << 16) |
            (@as(u32, @truncate(sg / cnt)) << 8) |
            @as(u32, @truncate(sb / cnt));
    }
}

/// 核心模糊实现（原始算法，无下采样）
fn boxBlurRectCore(x0: u32, y0: u32, rw: u32, rh: u32, radius: u32, passes: u32) void {
    if (rw > BLUR_MAX_LINE or rh > BLUR_MAX_LINE) return;

    const buf = getDrawBuffer();
    const pitch = fb_config.pitch;
    const bpp: u32 = @as(u32, fb_config.bpp) / 8;
    const x1 = x0 + rw;
    const y1 = y0 + rh;

    var pass: u32 = 0;
    while (pass < passes) : (pass += 1) {
        // Horizontal pass: process each row, store result in blur_line_h
        var row: u32 = y0;
        while (row < y1) : (row += 1) {
            const row_base: usize = @as(usize, row) * @as(usize, pitch) + @as(usize, x0) * @as(usize, bpp);
            // Read entire row into blur_line as packed XRGB u32
            var i: u32 = 0;
            while (i < rw) : (i += 1) {
                const off = row_base + @as(usize, i) * @as(usize, bpp);
                blur_line[i] = @as(u32, buf[off]) | (@as(u32, buf[off + 1]) << 8) | (@as(u32, buf[off + 2]) << 16);
            }
            // Running-sum horizontal blur (u64 sums: wide rects × large radius would overflow u32)
            i = 0;
            while (i < rw) : (i += 1) {
                const lo: u32 = if (i >= radius) i - radius else 0;
                const hi_u64 = @as(u64, i) + @as(u64, radius) + 1;
                const hi: u32 = if (hi_u64 > rw) rw else @intCast(hi_u64);
                if (hi <= lo) continue;
                const cnt: u64 = hi - lo;
                var sr: u64 = 0;
                var sg: u64 = 0;
                var sb: u64 = 0;
                var k: u32 = lo;
                while (k < hi) : (k += 1) {
                    const px = blur_line[k];
                    sr += @as(u64, px & 0xFF);
                    sg += @as(u64, (px >> 8) & 0xFF);
                    sb += @as(u64, (px >> 16) & 0xFF);
                }
                blur_line_h[i] = (@as(u32, @truncate(sr / cnt))) | (@as(u32, @truncate(sg / cnt)) << 8) | (@as(u32, @truncate(sb / cnt)) << 16);
            }
        }

        // Vertical pass: process each column, read from blur_line_h, write to buf
        var col: u32 = x0;
        while (col < x1) : (col += 1) {
            // Read column from blur_line_h (horizontal result) into blur_line
            var j: u32 = 0;
            while (j < rh) : (j += 1) {
                blur_line[j] = blur_line_h[j];
            }
            // Running-sum vertical blur
            j = 0;
            while (j < rh) : (j += 1) {
                const lo: u32 = if (j >= radius) j - radius else 0;
                const hi_u64 = @as(u64, j) + @as(u64, radius) + 1;
                const hi: u32 = if (hi_u64 > rh) rh else @intCast(hi_u64);
                if (hi <= lo) continue;
                const cnt: u64 = hi - lo;
                var sr: u64 = 0;
                var sg: u64 = 0;
                var sb: u64 = 0;
                var k: u32 = lo;
                while (k < hi) : (k += 1) {
                    const px = blur_line[k];
                    sr += @as(u64, px & 0xFF);
                    sg += @as(u64, (px >> 8) & 0xFF);
                    sb += @as(u64, (px >> 16) & 0xFF);
                }
                const off = @as(usize, y0 + j) * @as(usize, pitch) + @as(usize, col) * @as(usize, bpp);
                buf[off] = @truncate(sr / cnt);
                buf[off + 1] = @truncate(sg / cnt);
                buf[off + 2] = @truncate(sb / cnt);
            }
        }
    }
    total_draw_calls += 1;
}

/// Alpha-blend a tint color over a framebuffer rect with saturation control.
pub fn blendTintRect(x: i32, y: i32, w: i32, h: i32, tint: u32, alpha: u8, saturation: u8) void {
    if (w <= 0 or h <= 0) return;
    if (!config_ready) return;

    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, @intCast(w), fb_config.width);
    const y1: u32 = addU32Clamped(y0, @intCast(h), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const t_b: u32 = tint & 0xFF;
    const t_g: u32 = (tint >> 8) & 0xFF;
    const t_r: u32 = (tint >> 16) & 0xFF;
    const a: u32 = @min(@as(u32, alpha), 255);
    const inv_a: u32 = 255 - a;
    const sat: u32 = @min(@as(u32, saturation), 255);

    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();

    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        var px: u32 = x0;
        while (px < x1) : (px += 1) {
            const off = @as(usize, py) * @as(usize, fb_config.pitch) + @as(usize, px) * @as(usize, bytes_pp);
            var r: u32 = undefined;
            var g: u32 = undefined;
            var b: u32 = undefined;
            if (fb_config.pixel_bgr) {
                b = @as(u32, ptr[off]);
                g = @as(u32, ptr[off + 1]);
                r = @as(u32, ptr[off + 2]);
            } else {
                r = @as(u32, ptr[off]);
                g = @as(u32, ptr[off + 1]);
                b = @as(u32, ptr[off + 2]);
            }

            const lum: u32 = @truncate((@as(u64, r) * 77 + @as(u64, g) * 150 + @as(u64, b) * 29) >> 8);
            const inv_sat: u32 = 255 - sat;
            r = @min(255, @as(u32, @truncate((@as(u64, r) * sat + @as(u64, lum) * inv_sat) / 255)));
            g = @min(255, @as(u32, @truncate((@as(u64, g) * sat + @as(u64, lum) * inv_sat) / 255)));
            b = @min(255, @as(u32, @truncate((@as(u64, b) * sat + @as(u64, lum) * inv_sat) / 255)));

            const out_r: u32 = @min(255, @as(u32, @truncate((@as(u64, t_r) * a + @as(u64, r) * inv_a) / 255)));
            const out_g: u32 = @min(255, @as(u32, @truncate((@as(u64, t_g) * a + @as(u64, g) * inv_a) / 255)));
            const out_b: u32 = @min(255, @as(u32, @truncate((@as(u64, t_b) * a + @as(u64, b) * inv_a) / 255)));

            if (fb_config.pixel_bgr) {
                ptr[off] = @truncate(out_b);
                ptr[off + 1] = @truncate(out_g);
                ptr[off + 2] = @truncate(out_r);
            } else {
                ptr[off] = @truncate(out_r);
                ptr[off + 1] = @truncate(out_g);
                ptr[off + 2] = @truncate(out_b);
            }
            if (bytes_pp == 4) ptr[off + 3] = 0xFF;
        }
    }
    total_draw_calls += 1;
    markDirtyRegion(@intCast(x0), @intCast(y0), @intCast(x1 - x0), @intCast(y1 - y0));
}

/// Add a specular highlight (brightness boost that fades down) over a rect.
pub fn addSpecularBand(x: i32, y: i32, w: i32, band_h: i32, intensity: u32) void {
    if (w <= 0 or band_h <= 0) return;
    if (!config_ready) return;

    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, @intCast(w), fb_config.width);
    const y1: u32 = addU32Clamped(y0, @intCast(band_h), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const bh = y1 - y0;
    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();

    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        const t = py - y0;
        // u32 减法在 dist 估计偏大时会下溢触发 Debug panic；用 u64 归一化到 [0, intensity]
        const num = @as(u64, intensity) * @as(u64, t);
        const inc = num / @as(u64, @max(bh, 1));
        const boost: u32 = if (inc >= intensity) 0 else @intCast(@as(u64, intensity) - inc);

        var px: u32 = x0;
        while (px < x1) : (px += 1) {
            const off = pixelByteOffset(px, py, bytes_pp);
            var r: u32 = undefined;
            var g: u32 = undefined;
            var b: u32 = undefined;
            if (fb_config.pixel_bgr) {
                b = @as(u32, ptr[off]);
                g = @as(u32, ptr[off + 1]);
                r = @as(u32, ptr[off + 2]);
            } else {
                r = @as(u32, ptr[off]);
                g = @as(u32, ptr[off + 1]);
                b = @as(u32, ptr[off + 2]);
            }
            r = @min(r + boost, 255);
            g = @min(g + boost, 255);
            b = @min(b + boost, 255);
            if (fb_config.pixel_bgr) {
                ptr[off] = @truncate(b);
                ptr[off + 1] = @truncate(g);
                ptr[off + 2] = @truncate(r);
            } else {
                ptr[off] = @truncate(r);
                ptr[off + 1] = @truncate(g);
                ptr[off + 2] = @truncate(b);
            }
            if (bytes_pp == 4) ptr[off + 3] = 0xFF;
        }
    }
}

// ── Buffer Management ──

/// Forward copy using volatile destination writes so the compiler cannot fold
/// this into `@memcpy` (which panics in ReleaseSafe when src/dst overlap).
/// Used for scanout flips where identity-mapped GPA may alias if the PFN
/// allocator ever hands out a range overlapping the GOP region.
fn safeScanoutCopy(dst: [*]u8, src: [*]const u8, len: usize) void {
    const vdst: [*]volatile u8 = @volatileCast(dst);
    const word_size = @sizeOf(usize);
    const full = len / word_size;
    const tail = len % word_size;
    var wi: usize = 0;
    while (wi < full) : (wi += 1) {
        const off = wi * word_size;
        const w: usize = @as(*align(1) const usize, @ptrCast(src + off)).*;
        @as(*align(1) volatile usize, @ptrCast(vdst + off)).* = w;
    }
    const base = full * word_size;
    var ti: usize = 0;
    while (ti < tail) : (ti += 1) {
        vdst[base + ti] = src[base + ti];
    }
}

/// 大块 memcpy 到屏前/ramfb 后做内存栅栏，避免弱序模型下设备侧先看到旧像素（LoongArch 上尤为明显）。
fn fenceScanoutAfterMemcpy() void {
    fenceScanoutVisibleWrites();
}

/// 任意写入客户机线性帧缓冲（含直接绘制到 scanout）之后可调用，保证 Store 对设备可见（当前实现：LoongArch `dbar 0`）。
pub fn fenceScanoutVisibleWrites() void {
    switch (builtin.target.cpu.arch) {
        .loongarch64 => asm volatile ("dbar 0" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dsb sy" ::: .{ .memory = true }),
        else => {},
    }
}

pub fn flip() void {
    if (double_buffer_active) {
        const size = bytes_per_slot;
        const dst: [*]u8 = @ptrFromInt(fb_config.address);
        const src = backBufSrcPtr();
        safeScanoutCopy(dst, src, size);
        fenceScanoutAfterMemcpy();
        if (triple_buffer_active) {
            draw_slot ^= 1;
        }
    }
    dirty_count = 0;
    total_flips += 1;
}

pub fn flipDirty() void {
    if (double_buffer_active) {
        const src = backBufSrcPtr();
        if (dirty_count == 0 or dirty_count >= MAX_DIRTY_RECTS) {
            const size = @as(usize, fb_config.pitch) * @as(usize, fb_config.height);
            const dst: [*]u8 = @ptrFromInt(fb_config.address);
            safeScanoutCopy(dst, src, size);
            fenceScanoutAfterMemcpy();
        } else {
            const bytes_pp: usize = @as(usize, fb_config.bpp) / 8;
            const dst_base: [*]u8 = @ptrFromInt(fb_config.address);
            for (dirty_rects[0..dirty_count]) |r| {
                const rx0: u32 = if (r.x < 0) 0 else @intCast(r.x);
                const ry0: u32 = if (r.y < 0) 0 else @intCast(r.y);
                const rw: u32 = if (r.w < 0) 0 else @intCast(r.w);
                const rh: u32 = if (r.h < 0) 0 else @intCast(r.h);
                const rx1: u32 = addU32Clamped(rx0, rw, fb_config.width);
                const ry1: u32 = addU32Clamped(ry0, rh, fb_config.height);
                if (rx0 >= rx1 or ry0 >= ry1) continue;
                const row_bytes = @as(usize, rx1 - rx0) * bytes_pp;
                var py: u32 = ry0;
                while (py < ry1) : (py += 1) {
                    const off = pixelByteOffset(rx0, py, @intCast(bytes_pp));
                    safeScanoutCopy(dst_base + off, src + off, row_bytes);
                }
            }
            fenceScanoutAfterMemcpy();
        }
    }
    dirty_count = 0;
    total_flips += 1;
}

/// 自当前绘制缓冲拷贝矩形像素到 `dst`（按行紧密排列）。返回写入字节数。
pub fn copyDrawBufferRectBytes(dx: i32, dy: i32, w: i32, h: i32, dst: []u8) usize {
    if (w <= 0 or h <= 0) return 0;
    const bytes_pp: usize = @as(usize, fb_config.bpp) / 8;

    var x0: i32 = dx;
    var y0: i32 = dy;
    var cw: i32 = w;
    var ch: i32 = h;
    if (x0 < 0) {
        cw += x0;
        x0 = 0;
    }
    if (y0 < 0) {
        ch += y0;
        y0 = 0;
    }
    const fw: i32 = @intCast(fb_config.width);
    const fh: i32 = @intCast(fb_config.height);
    if (x0 >= fw or y0 >= fh) return 0;
    // i64 边界：`x0 + cw` 在 i32 上先加再比会在 Debug 下溢出 panic（与 material.rectScanEnd 注释同源）。
    {
        const x0i = @as(i64, x0);
        const y0i = @as(i64, y0);
        const fwi = @as(i64, fw);
        const fhi = @as(i64, fh);
        if (x0i + @as(i64, cw) > fwi) cw = @intCast(fwi - x0i);
        if (y0i + @as(i64, ch) > fhi) ch = @intCast(fhi - y0i);
    }
    if (cw <= 0 or ch <= 0) return 0;

    const row_bytes: usize = @as(usize, @intCast(cw)) * bytes_pp;
    const need: usize = @as(usize, @intCast(ch)) * row_bytes;
    if (dst.len < need) return 0;

    const ptr = getDrawBuffer();
    var dst_off: usize = 0;
    var row: i32 = 0;
    while (row < ch) : (row += 1) {
        const py: u32 = @intCast(y0 + row);
        const off: usize = @as(usize, py) * @as(usize, fb_config.pitch) + @as(usize, @intCast(x0)) * bytes_pp;
        const src_row = @as([*]u8, @volatileCast(ptr))[off .. off + row_bytes];
        safeScanoutCopy(dst[dst_off..].ptr, src_row.ptr, row_bytes);
        dst_off += row_bytes;
    }
    return dst_off;
}

/// 将 `src` 按行写回绘制缓冲（与 `copyDrawBufferRectBytes` 相同裁剪语义）。
pub fn pasteDrawBufferRectBytes(dx: i32, dy: i32, w: i32, h: i32, src: []const u8) void {
    if (w <= 0 or h <= 0) return;
    const bytes_pp: usize = @as(usize, fb_config.bpp) / 8;

    var x0: i32 = dx;
    var y0: i32 = dy;
    var cw: i32 = w;
    var ch: i32 = h;
    if (x0 < 0) {
        cw += x0;
        x0 = 0;
    }
    if (y0 < 0) {
        ch += y0;
        y0 = 0;
    }
    const fw: i32 = @intCast(fb_config.width);
    const fh: i32 = @intCast(fb_config.height);
    if (x0 >= fw or y0 >= fh) return;
    {
        const x0i = @as(i64, x0);
        const y0i = @as(i64, y0);
        const fwi = @as(i64, fw);
        const fhi = @as(i64, fh);
        if (x0i + @as(i64, cw) > fwi) cw = @intCast(fwi - x0i);
        if (y0i + @as(i64, ch) > fhi) ch = @intCast(fhi - y0i);
    }
    if (cw <= 0 or ch <= 0) return;

    const row_bytes: usize = @as(usize, @intCast(cw)) * bytes_pp;
    const need: usize = @as(usize, @intCast(ch)) * row_bytes;
    if (src.len < need) return;

    const ptr = getDrawBuffer();
    var src_off: usize = 0;
    var row: i32 = 0;
    while (row < ch) : (row += 1) {
        const py: u32 = @intCast(y0 + row);
        const off: usize = @as(usize, py) * @as(usize, fb_config.pitch) + @as(usize, @intCast(x0)) * bytes_pp;
        const dst_row = @as([*]u8, @volatileCast(ptr))[off .. off + row_bytes];
        safeScanoutCopy(dst_row.ptr, src[src_off..].ptr, row_bytes);
        src_off += row_bytes;
    }
}

pub fn isDoubleBuffered() bool {
    return double_buffer_active;
}

pub fn isTripleBuffered() bool {
    return triple_buffer_active;
}

/// 离屏槽数量（不含 GOP）：0 = 单缓冲直写屏前，1 = 双缓冲，2 = 三缓冲乒乓。
pub fn getOffscreenSlotCount() u32 {
    if (!double_buffer_active) return 0;
    return if (triple_buffer_active) 2 else 1;
}

/// 离屏区域总预留字节（所有槽之和）。
pub fn getOffscreenReservedBytes() usize {
    if (!double_buffer_active or bytes_per_slot == 0) return 0;
    return bytes_per_slot * @as(usize, getOffscreenSlotCount());
}

/// 可选：把当前 GOP 内容拷入离屏槽（配置 `display.seed_gop_to_back`）。
pub fn seedDrawBufferFromVisibleIfConfigured() void {
    if (!double_buffer_active or fb_config.address == 0 or bytes_per_slot == 0) return;
    if (!config_mod.isSeedDrawBufferFromGopEnabled()) return;
    const size = bytes_per_slot;
    const src: [*]const u8 = @ptrFromInt(fb_config.address);
    const nslots: u32 = if (triple_buffer_active) 2 else 1;
    var s: u32 = 0;
    while (s < nslots) : (s += 1) {
        const off = @as(usize, s) * size;
        const dst: [*]u8 = if (back_buffer_addr != 0)
            @ptrFromInt(back_buffer_addr + off)
        else
            @as([*]u8, @ptrCast(&back_buf)) + off;
        safeScanoutCopy(dst, src, size);
    }
}

/// 桌面启动摘要：与 AeroDesktopRuntime §3.1 对照「坐标 vs 像素」排查。
pub fn logDesktopPointerDiagnostics(virtio_input_active: bool, ps2_hw_ok: bool) void {
    if (!config_ready) return;
    klog.info("DesktopPointerDiag: double_buf=%s triple_buf=%s offscreen_slots=%u reserved_B=%u present_full_flip=%s seed_gop=%s fall_back_alloc=%s virtio_input=%s ps2_hw=%s — see docs/cn/AeroDesktopRuntime.md §3.1", .{
        if (double_buffer_active) "ON" else "OFF",
        if (triple_buffer_active) "ON" else "OFF",
        getOffscreenSlotCount(),
        @as(u32, @truncate(getOffscreenReservedBytes())),
        if (config_mod.isPresentFullFlipEnabled()) "ON" else "OFF",
        if (config_mod.isSeedDrawBufferFromGopEnabled()) "ON" else "OFF",
        if (config_mod.allowSingleBufferOnLargeAllocFail()) "ON" else "OFF",
        if (virtio_input_active) "active" else "inactive",
        if (ps2_hw_ok) "ok" else "no",
    });
}

/// GOP 几何一行摘要（排查 LoongArch UEFI / Multiboot 与盒式模糊成本：`w*h`）。
pub fn logDesktopGopSummary() void {
    if (!config_ready) return;
    klog.info("DesktopGOP: %ux%u pitch=%u bpp=%u (see DesktopManagerSpec blur tuning)", .{
        fb_config.width, fb_config.height, fb_config.pitch, fb_config.bpp,
    });
}

/// 帧缓冲 + 离屏内存一行摘要（回归 / QA）。
pub fn logFramebufferMemorySummary() void {
    if (!config_ready) return;
    const vis = @as(usize, fb_config.pitch) * @as(usize, fb_config.height);
    klog.info("FramebufferMem: visible_B=%u offscreen_B=%u total_managed_B=%u flips=%u", .{
        @as(u32, @truncate(vis)),
        @as(u32, @truncate(getOffscreenReservedBytes())),
        @as(u32, @truncate(vis + getOffscreenReservedBytes())),
        @as(u32, @truncate(total_flips)),
    });
}

// ── IRP Dispatch ──

fn fbDispatch(irp: *io.Irp) io.NTSTATUS {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        .ioctl => return handleIoctl(irp),
        else => {
            irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
            return io.STATUS_NOT_IMPLEMENTED;
        },
    }
}

fn handleIoctl(irp: *io.Irp) io.NTSTATUS {
    switch (irp.ioctl_code) {
        IOCTL_FB_GET_CONFIG => {
            irp.buffer_ptr = fb_config.address;
            irp.bytes_transferred = @intCast(@as(u64, fb_config.pitch) * @as(u64, fb_config.height));
            irp.complete(io.STATUS_SUCCESS, fb_config.width);
            return io.STATUS_SUCCESS;
        },
        IOCTL_FB_MAP_BUFFER => {
            irp.buffer_ptr = fb_config.address;
            irp.complete(io.STATUS_SUCCESS, @intCast(@as(u64, fb_config.pitch) * @as(u64, fb_config.height)));
            return io.STATUS_SUCCESS;
        },
        IOCTL_FB_FLIP => {
            flip();
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        IOCTL_FB_FILL_RECT => {
            if (irp.buffer_size < @sizeOf(FillRectRequest)) {
                irp.complete(io.STATUS_BUFFER_TOO_SMALL, 0);
                return io.STATUS_BUFFER_TOO_SMALL;
            }
            const req: *const FillRectRequest = @ptrFromInt(irp.buffer_ptr);
            fillRect(req.x, req.y, req.w, req.h, req.color);
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        IOCTL_FB_COPY_RECT => {
            if (irp.buffer_size < @sizeOf(CopyRectRequest)) {
                irp.complete(io.STATUS_BUFFER_TOO_SMALL, 0);
                return io.STATUS_BUFFER_TOO_SMALL;
            }
            const req: *const CopyRectRequest = @ptrFromInt(irp.buffer_ptr);
            copyRect(req.src_x, req.src_y, req.dst_x, req.dst_y, req.w, req.h);
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        IOCTL_FB_DRAW_LINE => {
            if (irp.buffer_size < @sizeOf(DrawLineRequest)) {
                irp.complete(io.STATUS_BUFFER_TOO_SMALL, 0);
                return io.STATUS_BUFFER_TOO_SMALL;
            }
            const req: *const DrawLineRequest = @ptrFromInt(irp.buffer_ptr);
            drawLineAA(req.x1, req.y1, req.x2, req.y2, req.color);
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        IOCTL_FB_GET_STATS => {
            if (irp.buffer_size < @sizeOf(FbStatsResponse)) {
                irp.complete(io.STATUS_BUFFER_TOO_SMALL, 0);
                return io.STATUS_BUFFER_TOO_SMALL;
            }
            const stats: *FbStatsResponse = @ptrFromInt(irp.buffer_ptr);
            stats.* = .{
                .total_draw_calls = total_draw_calls,
                .total_flips = total_flips,
                .width = fb_config.width,
                .height = fb_config.height,
                .bpp = fb_config.bpp,
                .double_buffer_active = double_buffer_active,
                .triple_buffer_active = triple_buffer_active,
                .reserved = [_]u8{0} ** 2,
            };
            irp.bytes_transferred = @sizeOf(FbStatsResponse);
            irp.complete(io.STATUS_SUCCESS, @sizeOf(FbStatsResponse));
            return io.STATUS_SUCCESS;
        },
        else => {
            irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
            return io.STATUS_NOT_IMPLEMENTED;
        },
    }
}

// ── State Query ──

pub fn getConfig() *const FramebufferConfig {
    return &fb_config;
}

pub fn getWidth() u32 {
    return fb_config.width;
}

pub fn getHeight() u32 {
    return fb_config.height;
}

pub fn getBpp() u8 {
    return fb_config.bpp;
}

/// 与 VirtIO `virtio_gpu_mem_entry` 同布局（guest 物理地址 + 长度），供 `RESOURCE_ATTACH_BACKING` 多段路径；定义于此避免 `framebuffer` ↔ `virtio_gpu_spec` 循环依赖。
pub const VirtioBackingMemEntry = struct {
    addr: u64,
    length: u32,
};

/// 将屏前缓冲（`fb_config.address`，与 `getFrontBufferPhysContiguousForVirtio` 同一可见面）按 **guest 物理连续段** 切分为多枚 mem_entry。
/// 每段长度不超过 `u32::MAX`；段数写入 `out` 前缀，返回段数；不满足 32bpp / 紧密 pitch / 长度页对齐等条件时返回 `null`。
pub fn fillFrontBufferVirtioBackingEntries(out: []VirtioBackingMemEntry) ?usize {
    if (!config_ready or fb_config.address == 0) return null;
    if (fb_config.bpp != 32) return null;
    const w = fb_config.width;
    const h = fb_config.height;
    if (w == 0 or h == 0) return null;
    const pitch_u: u64 = fb_config.pitch;
    const need_pitch: u64 = @as(u64, w) * 4;
    if (pitch_u != need_pitch) return null;
    const len: u64 = pitch_u * @as(u64, h);
    if (len == 0 or len > 64 * 1024 * 1024) return null;
    const page: u64 = 4096;
    if (len % page != 0) return null;

    const base: usize = fb_config.address;
    var off: u64 = 0;
    var count: usize = 0;
    while (off < len) {
        const pa0: u64 = @intCast(vm.kernelVirtToPhys(base + @as(usize, @intCast(off))));
        var pages: u64 = 0;
        while (off + pages * page < len) : (pages += 1) {
            const page_off = off + pages * page;
            const p: u64 = @intCast(vm.kernelVirtToPhys(base + @as(usize, @intCast(page_off))));
            if (p != pa0 + pages * page) break;
        }
        if (pages == 0) return null;
        const nbytes: u64 = pages * page;
        if (nbytes > std.math.maxInt(u32)) return null;
        if (count >= out.len) return null;
        out[count] = .{ .addr = pa0, .length = @intCast(nbytes) };
        count += 1;
        off += nbytes;
    }
    return count;
}

/// 桌面 / VirtIO 初始化时调用：说明屏前缓冲是否满足单段连续、或多段 attach 可行性（不依赖 `virtio_gpu_pci`，无循环引用）。
pub fn logVirtioScanoutReadiness() void {
    if (!config_ready or fb_config.address == 0) {
        klog.debug("VirtIO scanout hints: framebuffer not ready", .{});
        return;
    }
    if (fb_config.bpp != 32) {
        klog.info("VirtIO scanout hints: bpp=%u (need 32)", .{fb_config.bpp});
        return;
    }
    const w = fb_config.width;
    const h = fb_config.height;
    if (w == 0 or h == 0) {
        klog.debug("VirtIO scanout hints: zero dimensions", .{});
        return;
    }
    const pitch_u = fb_config.pitch;
    const need_pitch: u32 = w *| 4;
    if (pitch_u != need_pitch) {
        klog.info("VirtIO scanout hints: pitch=%u != width*4=%u (tight stride required for B8G8R8X8 scanout)", .{ pitch_u, need_pitch });
    }
    if (getFrontBufferPhysContiguousForVirtio()) |_| {
        klog.info("VirtIO scanout hints: front buffer single contiguous GPA span (legacy attach path ok)", .{});
        return;
    }
    var entries: [virtio_gpu_spec.max_virtio_backing_mem_entries]VirtioBackingMemEntry = undefined;
    if (fillFrontBufferVirtioBackingEntries(&entries)) |n| {
        klog.info("VirtIO scanout hints: multi-entry backing ok (%u virtio_gpu_mem_entry segments)", .{n});
        return;
    }
    klog.warn("VirtIO scanout hints: cannot derive backing entries (check VM mapping / pitch)", .{});
}

/// 屏前线性缓冲（`fb_config.address`）在 **4KiB 页**上物理连续时的 GPA 与长度，供 VirtIO-GPU `RESOURCE_ATTACH_BACKING`。
/// 要求 `pitch == width*4`（与 `FORMAT_B8G8R8X8_UNORM` 紧密 stride 一致）。双缓冲下 flip 写入该区间后由 `RESOURCE_FLUSH` 通知设备。
pub fn getFrontBufferPhysContiguousForVirtio() ?struct { base: u64, len: u64 } {
    if (!config_ready or fb_config.address == 0) return null;
    if (fb_config.bpp != 32) return null;
    const w = fb_config.width;
    const h = fb_config.height;
    if (w == 0 or h == 0) return null;
    const pitch_u: u64 = fb_config.pitch;
    const need_pitch: u64 = @as(u64, w) * 4;
    if (pitch_u != need_pitch) return null;
    const len: u64 = pitch_u * @as(u64, h);
    if (len == 0) return null;
    if (len > 64 * 1024 * 1024) return null; // 单 attach `length` u32 上限内保守 cap
    const page: u64 = 4096;
    if (len % page != 0) return null;
    var off: u64 = 0;
    var prev_phys: ?u64 = null;
    while (off < len) {
        const va = fb_config.address + off;
        const pa: u64 = @intCast(vm.kernelVirtToPhys(va));
        if (prev_phys) |pp| {
            if (pa != pp + page) return null;
        }
        prev_phys = pa;
        off += page;
    }
    const base: u64 = @intCast(vm.kernelVirtToPhys(fb_config.address));
    return .{ .base = base, .len = len };
}

pub fn getPitch() u32 {
    return fb_config.pitch;
}

pub fn getAddress() usize {
    return fb_config.address;
}

/// 主帧缓冲地址（与 `getAddress()` 等价,语义更明确,推荐在新代码中使用）.
pub fn getFrontbufferAddress() usize {
    return fb_config.address;
}

pub fn isInitialized() bool {
    return config_ready;
}

pub fn isDriverRegistered() bool {
    return driver_initialized;
}

pub fn getTotalDrawCalls() u64 {
    return total_draw_calls;
}

pub fn getTotalFlips() u64 {
    return total_flips;
}

// ── Initialization ──

fn zeroHeapBack(total_bytes: usize) void {
    const p: [*]u8 = @ptrFromInt(back_buffer_addr);
    @memset(p[0..total_bytes], 0);
    if (back_buffer_size > total_bytes) {
        @memset(p[total_bytes..back_buffer_size], 0);
    }
}

pub fn init(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8, pixel_bgr: bool) void {
    const required = @as(usize, pitch) * @as(usize, height);
    if (back_buffer_heap_nframes > 0 and back_buffer_addr != 0) {
        if (frame_mod.getKernelFrameAllocator()) |fa_rel| {
            phys_pb.freeContiguousPagesWithSource(
                fa_rel,
                @as(u64, @truncate(back_buffer_addr)),
                back_buffer_heap_nframes,
                back_heap_contig_source,
                back_heap_contig_order,
            );
        }
    }
    back_buffer_addr = 0;
    back_buffer_size = 0;
    back_buffer_heap_nframes = 0;
    back_heap_contig_source = .frame_bitmap;
    back_heap_contig_order = 0;
    double_buffer_active = false;
    triple_buffer_active = false;
    draw_slot = 0;
    bytes_per_slot = 0;

    const want_db_base = config_mod.isDoubleBufferEnabled() and required > 0 and addr != 0;
    var want_triple = want_db_base and config_mod.isTripleBufferEnabled();
    const allow_single_on_fail = config_mod.allowSingleBufferOnLargeAllocFail();

    if (want_db_base) {
        bytes_per_slot = required;
        const total_for_triple = required * 2;

        // 小分辨率（单缓冲 <= 2MB）：使用静态缓冲区
        if (required <= STATIC_BACK_BUF_MAX and (!want_triple or total_for_triple <= STATIC_BACK_BUF_MAX)) {
            double_buffer_active = true;
            triple_buffer_active = false; // 静态缓冲区仅支持单缓冲
            if (!back_buf_initialized) {
                @memset(back_buf[0..required], 0);
                back_buf_initialized = true;
            }
        }
        // 需要堆分配的情况（单缓冲 > 2MB，或需要三缓冲 > 2MB）
        else if (frame_mod.getKernelFrameAllocator()) |fa| {
            if (want_triple and total_for_triple > STATIC_BACK_BUF_MAX) {
                // 三缓冲：需要堆分配
                const nframes2 = (total_for_triple + frame_mod.FRAME_SIZE - 1) / frame_mod.FRAME_SIZE;
                const ac = phys_pb.allocContiguousPagesWithSource(fa, nframes2);
                if (ac.phys) |base_phys| {
                    back_heap_contig_source = ac.source;
                    back_heap_contig_order = ac.order;
                    back_buffer_addr = @as(usize, @truncate(base_phys));
                    back_buffer_heap_nframes = nframes2;
                    back_buffer_size = nframes2 * frame_mod.FRAME_SIZE;
                    double_buffer_active = true;
                    triple_buffer_active = true;
                    zeroHeapBack(total_for_triple);
                    klog.info("Framebuffer: heap ping-pong %u pages phys=0x%x (%u bytes 2 slots)", .{
                        nframes2, back_buffer_addr, total_for_triple,
                    });
                } else if (allow_single_on_fail) {
                    klog.warn("Framebuffer: triple alloc failed; falling back to single buffer", .{});
                    want_triple = false;
                }
            }
            // 单缓冲大分辨率：堆分配
            if (!double_buffer_active) {
                const nframes = (required + frame_mod.FRAME_SIZE - 1) / frame_mod.FRAME_SIZE;
                const ac = phys_pb.allocContiguousPagesWithSource(fa, nframes);
                if (ac.phys) |base_phys| {
                    back_heap_contig_source = ac.source;
                    back_heap_contig_order = ac.order;
                    back_buffer_addr = @as(usize, @truncate(base_phys));
                    back_buffer_heap_nframes = nframes;
                    back_buffer_size = nframes * frame_mod.FRAME_SIZE;
                    double_buffer_active = true;
                    triple_buffer_active = false;
                    zeroHeapBack(required);
                    klog.info("Framebuffer: heap back buffer %u pages phys=0x%x (%u bytes)", .{
                        nframes, back_buffer_addr, required,
                    });
                } else if (allow_single_on_fail) {
                    klog.warn("Framebuffer: allocContiguous failed (%u bytes); strategy=single_buffer_direct (GOP)", .{required});
                } else {
                    klog.err("Framebuffer: allocContiguous failed and fall_back_single_on_alloc_fail=false; double_buf=OFF", .{});
                }
            }
        } else if (allow_single_on_fail) {
            klog.warn("Framebuffer: no kernel frame allocator; large FB strategy=single_buffer_direct", .{});
        } else {
            klog.err("Framebuffer: no allocator and fall_back_single_on_alloc_fail=false; double_buf=OFF", .{});
        }
    }

    if (double_buffer_active and addr != 0 and bytes_per_slot > 0) {
        const back_start = if (back_buffer_addr != 0) back_buffer_addr else @intFromPtr(&back_buf);
        const back_end = back_start + bytes_per_slot;
        const fb_end = addr + required;
        if (back_start < fb_end and addr < back_end) {
            klog.err("Framebuffer: OVERLAP DETECTED — GOP [0x%x..0x%x) vs back [0x%x..0x%x); disabling double buffer to avoid alias panic", .{
                @as(u32, @truncate(addr)),     @as(u32, @truncate(fb_end)),
                @as(u32, @truncate(back_start)), @as(u32, @truncate(back_end)),
            });
            double_buffer_active = false;
            triple_buffer_active = false;
        }
    }

    fb_config = .{
        .address = addr,
        .width = width,
        .height = height,
        .pitch = pitch,
        .bpp = bpp,
        .pixel_format = if (bpp == 32) .xrgb8888 else if (bpp == 24) .rgb888 else .rgb565,
        .double_buffer = double_buffer_active,
        .pixel_bgr = pixel_bgr,
    };

    config_ready = (addr != 0 and width > 0 and height > 0 and bpp > 0);
    syncMonitorLayoutsFromPrimary();

    seedDrawBufferFromVisibleIfConfigured();

    if (!driver_initialized) {
        driver_idx = io.registerDriver("\\Driver\\Framebuf", fbDispatch) orelse {
            klog.err("Framebuffer: Failed to register IO driver (rendering still works)", .{});
            klog.info("Framebuffer Driver: %ux%u@%ubpp, pitch=%u, addr=0x%x, double_buf=%s triple=%s", .{
                width,                                     height,                                    bpp, pitch, addr,
                if (double_buffer_active) "ON" else "OFF", if (triple_buffer_active) "ON" else "OFF",
            });
            return;
        };

        device_idx = io.createDevice("\\Device\\Framebuf0", .framebuffer, driver_idx) orelse {
            klog.err("Framebuffer: Failed to create IO device (rendering still works)", .{});
            klog.info("Framebuffer Driver: %ux%u@%ubpp, pitch=%u, addr=0x%x, double_buf=%s triple=%s", .{
                width,                                     height,                                    bpp, pitch, addr,
                if (double_buffer_active) "ON" else "OFF", if (triple_buffer_active) "ON" else "OFF",
            });
            return;
        };

        driver_initialized = true;

        klog.info("Framebuffer Driver: %ux%u@%ubpp, pitch=%u, addr=0x%x, double_buf=%s triple=%s offscreen_B=%u", .{
            width,                                     height,                                    bpp,                                              pitch, addr,
            if (double_buffer_active) "ON" else "OFF", if (triple_buffer_active) "ON" else "OFF", @as(u32, @truncate(getOffscreenReservedBytes())),
        });
    } else {
        klog.info("Framebuffer: reconfigured %ux%u@%ubpp pitch=%u addr=0x%x double_buf=%s", .{
            width, height, bpp, pitch, addr, if (double_buffer_active) "ON" else "OFF",
        });
    }
    logFramebufferMemorySummary();
}

// ── Embedded 8x16 bitmap font (ASCII 32-126 + fallback) ──

fn getGlyph(ch: u8) *const [16]u8 {
    if (ch >= 32 and ch < 127) {
        return &font_8x16[ch - 32];
    }
    return &font_8x16[95];
}

const font_8x16 = [96][16]u8{
    // 32: space
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 33: !
    .{ 0x00, 0x00, 0x18, 0x3C, 0x3C, 0x3C, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    // 34: "
    .{ 0x00, 0x66, 0x66, 0x66, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 35: #
    .{ 0x00, 0x00, 0x00, 0x6C, 0x6C, 0xFE, 0x6C, 0x6C, 0xFE, 0x6C, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 36: $
    .{ 0x18, 0x18, 0x7C, 0xC6, 0xC2, 0xC0, 0x7C, 0x06, 0x06, 0x86, 0xC6, 0x7C, 0x18, 0x18, 0x00, 0x00 },
    // 37: %
    .{ 0x00, 0x00, 0x00, 0x00, 0xC2, 0xC6, 0x0C, 0x18, 0x30, 0x60, 0xC6, 0x86, 0x00, 0x00, 0x00, 0x00 },
    // 38: &
    .{ 0x00, 0x00, 0x38, 0x6C, 0x6C, 0x38, 0x76, 0xDC, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    // 39: '
    .{ 0x00, 0x30, 0x30, 0x30, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 40: (
    .{ 0x00, 0x00, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00 },
    // 41: )
    .{ 0x00, 0x00, 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00 },
    // 42: *
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 43: +
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 44: ,
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x18, 0x30, 0x00, 0x00, 0x00 },
    // 45: -
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 46: .
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    // 47: /
    .{ 0x00, 0x00, 0x00, 0x00, 0x02, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00, 0x00, 0x00, 0x00 },
    // 48-57: 0-9
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xCE, 0xDE, 0xF6, 0xE6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x18, 0x38, 0x78, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0xC6, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0x06, 0x06, 0x3C, 0x06, 0x06, 0x06, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x0C, 0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x0C, 0x0C, 0x1E, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0xC0, 0xC0, 0xC0, 0xFC, 0x06, 0x06, 0x06, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x38, 0x60, 0xC0, 0xC0, 0xFC, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0xC6, 0x06, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x30, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0x7E, 0x06, 0x06, 0x06, 0x0C, 0x78, 0x00, 0x00, 0x00, 0x00 },
    // 58: :
    .{ 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 59: ;
    .{ 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00 },
    // 60-62: < = >
    .{ 0x00, 0x00, 0x00, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x00, 0x00, 0x00, 0x00 },
    // 63: ?
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0x0C, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    // 64: @
    .{ 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xDE, 0xDE, 0xDE, 0xDC, 0xC0, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    // 65-90: A-Z
    .{ 0x00, 0x00, 0x10, 0x38, 0x6C, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFC, 0x66, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x66, 0x66, 0xFC, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x66, 0xC2, 0xC0, 0xC0, 0xC0, 0xC0, 0xC2, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xF8, 0x6C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x6C, 0xF8, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0x66, 0x62, 0x68, 0x78, 0x68, 0x60, 0x62, 0x66, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0x66, 0x62, 0x68, 0x78, 0x68, 0x60, 0x60, 0x60, 0xF0, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x66, 0xC2, 0xC0, 0xC0, 0xDE, 0xC6, 0xC6, 0x66, 0x3A, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0xCC, 0xCC, 0xCC, 0x78, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xE6, 0x66, 0x66, 0x6C, 0x78, 0x78, 0x6C, 0x66, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xF0, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x62, 0x66, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xEE, 0xFE, 0xFE, 0xD6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xE6, 0xF6, 0xFE, 0xDE, 0xCE, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFC, 0x66, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x60, 0xF0, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xD6, 0xDE, 0x7C, 0x0C, 0x0E, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFC, 0x66, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0x60, 0x38, 0x0C, 0x06, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFF, 0xDB, 0x99, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x10, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xD6, 0xD6, 0xD6, 0xFE, 0xEE, 0x6C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0x6C, 0x7C, 0x38, 0x38, 0x7C, 0x6C, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0xC6, 0x86, 0x0C, 0x18, 0x30, 0x60, 0xC2, 0xC6, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    // 91-96: [ \ ] ^ _ `
    .{ 0x00, 0x00, 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x80, 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x10, 0x38, 0x6C, 0xC6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00 },
    .{ 0x00, 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 97-122: a-z
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xE0, 0x60, 0x60, 0x78, 0x6C, 0x66, 0x66, 0x66, 0x66, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xC0, 0xC0, 0xC0, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x1C, 0x0C, 0x0C, 0x3C, 0x6C, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xFE, 0xC0, 0xC0, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x1C, 0x36, 0x32, 0x30, 0x78, 0x30, 0x30, 0x30, 0x30, 0x78, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x76, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x7C, 0x0C, 0xCC, 0x78, 0x00 },
    .{ 0x00, 0x00, 0xE0, 0x60, 0x60, 0x6C, 0x76, 0x66, 0x66, 0x66, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x18, 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x06, 0x06, 0x00, 0x0E, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x66, 0x66, 0x3C, 0x00 },
    .{ 0x00, 0x00, 0xE0, 0x60, 0x60, 0x66, 0x6C, 0x78, 0x78, 0x6C, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xE6, 0xFF, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xDC, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xDC, 0x66, 0x66, 0x66, 0x66, 0x66, 0x7C, 0x60, 0x60, 0xF0, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x76, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x7C, 0x0C, 0x0C, 0x1E, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xDC, 0x76, 0x66, 0x60, 0x60, 0x60, 0xF0, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0x60, 0x38, 0x0C, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x10, 0x30, 0x30, 0xFC, 0x30, 0x30, 0x30, 0x30, 0x36, 0x1C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0xC6, 0xD6, 0xD6, 0xD6, 0xFE, 0x6C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0x6C, 0x38, 0x38, 0x38, 0x6C, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7E, 0x06, 0x0C, 0xF8, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE, 0xCC, 0x18, 0x30, 0x60, 0xC6, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    // 123-126: { | } ~
    .{ 0x00, 0x00, 0x0E, 0x18, 0x18, 0x18, 0x70, 0x18, 0x18, 0x18, 0x18, 0x0E, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x70, 0x18, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x18, 0x18, 0x70, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 127: fallback (solid block)
    .{ 0x00, 0x00, 0x00, 0x00, 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00 },
};
