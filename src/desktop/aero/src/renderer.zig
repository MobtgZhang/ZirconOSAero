//! Renderer - ZirconOS Aero Rendering Abstraction Layer
//! Provides a platform-independent drawing interface with Aero-specific
//! enhancements: soft shadow (8px), glass blur, rounded corner support,
//! and glow effects for DWM-style composition.

const theme = @import("theme.zig");

pub const COLORREF = theme.COLORREF;

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
        return self.x < other.x + other.w and
            self.x + self.w > other.x and
            self.y < other.y + other.h and
            self.y + self.h > other.y;
    }

    pub fn intersection(self: Rect, other: Rect) Rect {
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.x + self.w, other.x + other.w);
        const y2 = @min(self.y + self.h, other.y + other.h);
        if (x2 <= x1 or y2 <= y1) return .{};
        return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
    }

    pub fn union_(self: Rect, other: Rect) Rect {
        if (self.w == 0 or self.h == 0) return other;
        if (other.w == 0 or other.h == 0) return self;
        const x1 = @min(self.x, other.x);
        const y1 = @min(self.y, other.y);
        const x2 = @max(self.x + self.w, other.x + other.w);
        const y2 = @max(self.y + self.h, other.y + other.h);
        return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn offset(self: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = self.x + dx, .y = self.y + dy, .w = self.w, .h = self.h };
    }

    pub fn inset(self: Rect, d: i32) Rect {
        return .{
            .x = self.x + d,
            .y = self.y + d,
            .w = @max(self.w - d * 2, 0),
            .h = @max(self.h - d * 2, 0),
        };
    }
};

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Size = struct {
    w: i32 = 0,
    h: i32 = 0,
};

pub const TextAlignment = enum(u8) {
    left = 0,
    center = 1,
    right = 2,
};

pub const FontWeight = enum(u8) {
    normal = 0,
    bold = 1,
};

pub const FontSpec = struct {
    name: []const u8 = theme.FONT_SYSTEM,
    size: i32 = theme.FONT_SYSTEM_SIZE,
    weight: FontWeight = .normal,
};

pub const GradientDirection = enum(u8) {
    horizontal = 0,
    vertical = 1,
};

pub const RenderOps = struct {
    fill_rect: ?*const fn (rect: Rect, color: COLORREF) void = null,
    draw_rect: ?*const fn (rect: Rect, color: COLORREF, width: i32) void = null,
    draw_line: ?*const fn (x1: i32, y1: i32, x2: i32, y2: i32, color: COLORREF) void = null,
    draw_gradient: ?*const fn (rect: Rect, start: COLORREF, end: COLORREF, dir: GradientDirection) void = null,
    draw_round_rect: ?*const fn (rect: Rect, color: COLORREF, radius: i32) void = null,
    draw_text: ?*const fn (text: []const u8, rect: Rect, color: COLORREF, font: FontSpec, alignment: TextAlignment) void = null,
    draw_icon: ?*const fn (icon_id: u32, x: i32, y: i32, size: i32) void = null,
    draw_bitmap: ?*const fn (bitmap_id: u32, dest: Rect) void = null,
    set_clip: ?*const fn (rect: Rect) void = null,
    clear_clip: ?*const fn () void = null,
    blit_surface: ?*const fn (surface_id: u32, dest: Rect, alpha: u8) void = null,
    flush: ?*const fn () void = null,
    draw_blur: ?*const fn (rect: Rect, radius: i32) void = null,
    fill_rect_alpha: ?*const fn (rect: Rect, color: COLORREF, alpha: u8) void = null,
    draw_glow: ?*const fn (rect: Rect, color: COLORREF, radius: i32) void = null,
};

var render_ops: RenderOps = .{};

pub fn setRenderOps(ops: RenderOps) void {
    render_ops = ops;
}

pub fn getRenderOps() *const RenderOps {
    return &render_ops;
}

pub fn fillRect(rect: Rect, color: COLORREF) void {
    if (render_ops.fill_rect) |f| f(rect, color);
}

pub fn drawRect(rect: Rect, color: COLORREF, width: i32) void {
    if (render_ops.draw_rect) |f| f(rect, color, width);
}

pub fn drawLine(x1: i32, y1: i32, x2: i32, y2: i32, color: COLORREF) void {
    if (render_ops.draw_line) |f| f(x1, y1, x2, y2, color);
}

pub fn drawGradient(rect: Rect, start: COLORREF, end: COLORREF, dir: GradientDirection) void {
    if (render_ops.draw_gradient) |f| f(rect, start, end, dir);
}

pub fn drawRoundRect(rect: Rect, color: COLORREF, radius: i32) void {
    if (render_ops.draw_round_rect) |f| f(rect, color, radius);
}

pub fn drawText(text: []const u8, rect: Rect, color: COLORREF, font: FontSpec, alignment: TextAlignment) void {
    if (render_ops.draw_text) |f| f(text, rect, color, font, alignment);
}

pub fn drawIcon(icon_id: u32, x: i32, y: i32, size: i32) void {
    if (render_ops.draw_icon) |f| f(icon_id, x, y, size);
}

pub fn drawBitmap(bitmap_id: u32, dest: Rect) void {
    if (render_ops.draw_bitmap) |f| f(bitmap_id, dest);
}

pub fn setClip(rect: Rect) void {
    if (render_ops.set_clip) |f| f(rect);
}

pub fn clearClip() void {
    if (render_ops.clear_clip) |f| f();
}

pub fn blitSurface(surface_id: u32, dest: Rect, alpha: u8) void {
    if (render_ops.blit_surface) |f| f(surface_id, dest, alpha);
}

pub fn flushRender() void {
    if (render_ops.flush) |f| f();
}

pub fn drawHGradient(rect: Rect, start_color: COLORREF, end_color: COLORREF) void {
    drawGradient(rect, start_color, end_color, .horizontal);
}

pub fn drawVGradient(rect: Rect, start_color: COLORREF, end_color: COLORREF) void {
    drawGradient(rect, start_color, end_color, .vertical);
}

pub fn drawBlur(rect: Rect, radius: i32) void {
    if (render_ops.draw_blur) |f| f(rect, radius);
}

pub fn fillRectAlpha(rect: Rect, color: COLORREF, alpha: u8) void {
    if (render_ops.fill_rect_alpha) |f| {
        f(rect, color, alpha);
    } else {
        fillRect(rect, theme.alphaBlend(color, theme.RGB(0xFF, 0xFF, 0xFF), alpha));
    }
}

pub fn drawGlow(rect: Rect, color: COLORREF, radius: i32) void {
    if (render_ops.draw_glow) |f| {
        f(rect, color, radius);
    }
}

/// Aero-style 8px soft shadow with graduated opacity
pub fn drawShadow(rect: Rect, shadow_size: i32) void {
    const shadow_color = theme.RGB(0, 0, 0);
    var i: i32 = 0;
    while (i < shadow_size) : (i += 1) {
        const base_alpha: i32 = 30;
        const alpha_step: u8 = @intCast(@max(0, base_alpha - @divTrunc(base_alpha * i, shadow_size)));
        const shadow_right = Rect{
            .x = rect.x + rect.w + i,
            .y = rect.y + shadow_size,
            .w = 1,
            .h = rect.h,
        };
        fillRect(shadow_right, theme.alphaBlend(shadow_color, theme.RGB(0xFF, 0xFF, 0xFF), alpha_step));
        const shadow_bottom = Rect{
            .x = rect.x + shadow_size,
            .y = rect.y + rect.h + i,
            .w = rect.w,
            .h = 1,
        };
        fillRect(shadow_bottom, theme.alphaBlend(shadow_color, theme.RGB(0xFF, 0xFF, 0xFF), alpha_step));
    }
}

/// Aero-style glass frame with rounded top corners
pub fn draw3DFrame(rect: Rect, raised: bool) void {
    const colors = theme.getColors();
    if (theme.isGlassEnabled()) {
        const border_color = if (raised) colors.window_border_active else colors.button_shadow;
        drawRoundRect(rect, border_color, theme.TITLEBAR_CORNER_RADIUS);
    } else {
        const light = if (raised) colors.button_highlight else colors.button_shadow;
        const dark = if (raised) colors.button_shadow else colors.button_highlight;
        drawLine(rect.x, rect.y, rect.x + rect.w - 1, rect.y, light);
        drawLine(rect.x, rect.y, rect.x, rect.y + rect.h - 1, light);
        drawLine(rect.x + rect.w - 1, rect.y, rect.x + rect.w - 1, rect.y + rect.h - 1, dark);
        drawLine(rect.x, rect.y + rect.h - 1, rect.x + rect.w - 1, rect.y + rect.h - 1, dark);
    }
}

/// Draw Aero glass surface (blur + translucent color overlay)
pub fn drawGlassSurface(rect: Rect) void {
    const colors = theme.getColors();
    const gp = theme.getGlassParams();
    if (theme.isGlassEnabled()) {
        drawBlur(rect, @as(i32, gp.blur_radius));
        fillRectAlpha(rect, gp.tint_color, gp.tint_opacity);
    } else {
        drawVGradient(rect, colors.titlebar_active_top, colors.titlebar_active_bottom);
    }
}

/// Full DWM glass window frame (win7Desktop.md pipeline):
///   1. Soft shadow → 2. Background blur → 3. Desaturate/tint → 4. Specular highlight → 5. Border
pub fn renderDwmWindowFrame(frame_rect: Rect, titlebar_h: i32) void {
    drawShadow(frame_rect, theme.WINDOW_SHADOW_SIZE);

    const glass_rect = Rect{
        .x = frame_rect.x,
        .y = frame_rect.y,
        .w = frame_rect.w,
        .h = titlebar_h,
    };
    drawGlassSurface(glass_rect);

    if (theme.isGlassEnabled()) {
        const specular_h = @divTrunc(titlebar_h, 3);
        if (specular_h > 1) {
            const highlight_rect = Rect{
                .x = glass_rect.x + 1,
                .y = glass_rect.y + 1,
                .w = glass_rect.w - 2,
                .h = specular_h,
            };
            fillRectAlpha(highlight_rect, theme.RGB(0xFF, 0xFF, 0xFF), 40);
        }
    }

    draw3DFrame(frame_rect, true);
}

/// Render DWM-style desktop wallpaper background (solid color fallback)
pub fn renderDesktopBackground(rect: Rect) void {
    fillRect(rect, theme.getColors().desktop_background);
}

/// DWM glass taskbar (win7Desktop.md: taskbar shares glass composition)
pub fn renderGlassTaskbar(rect: Rect) void {
    const gp = theme.getGlassParams();
    if (theme.isGlassEnabled()) {
        drawBlur(rect, @as(i32, gp.blur_radius));
        fillRectAlpha(rect, theme.taskbar_glass_tint, theme.taskbar_glass_opacity);
        const edge = Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 };
        fillRect(edge, theme.taskbar_top_edge);
    } else {
        drawVGradient(rect, theme.taskbar_glass_tint, theme.taskbar_bottom);
    }
}
