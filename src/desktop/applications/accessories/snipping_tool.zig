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
// Module: src/desktop/applications/accessories/snipping_tool.zig
// Purpose: Windows 7 style Snipping Tool - Enhanced Implementation
//
// This is an independent clean-room implementation.
// Clean Room: Based on public Win7 UI behavior only. No source code copied.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const builtin_apps = @import("../../kernel/shell/builtin_apps.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

/// Snipping mode - selection type for screen capture
pub const SnipMode = enum {
    freeform,
    rectangular,
    window,
    full_screen,
};

/// Delay timer for delayed capture (0 = no delay)
pub const MAX_DELAY_SECONDS = 5;

/// Freeform polygon point for irregular selection
const MAX_POLYGON_POINTS = 256;

/// Snipping tool state
pub const SnippingTool = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    focused: bool,
    mode: SnipMode,
    is_capturing: bool,
    capture_in_progress: bool,

    // Rectangular selection
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,

    // Freeform polygon selection
    polygon_points: [MAX_POLYGON_POINTS]struct { x: i32, y: i32 },
    polygon_count: usize,
    is_drawing_polygon: bool,

    // Delayed capture
    delay_seconds: u8,
    delay_countdown: i32,
    capture_scheduled: bool,

    // Captured image
    captured_image: []u8,
    captured_width: u32,
    captured_height: u32,
    has_capture: bool,

    // UI state
    caption_hover: CaptionButtonType,
    hover_new: bool,
    hover_mode: i32,
    hover_delay: i32,
    hover_send: bool,

    // Preview scroll
    preview_scroll_x: i32,

    // Instructions page
    instruction_page: u8,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create() SnippingTool {
        var cap: [640 * 480 * 4]u8 = undefined;
        return .{
            .x = 100,
            .y = 100,
            .width = 420,
            .height = 380,
            .visible = true,
            .focused = false,
            .mode = .rectangular,
            .is_capturing = false,
            .capture_in_progress = false,
            .start_x = 0,
            .start_y = 0,
            .end_x = 0,
            .end_y = 0,
            .polygon_points = undefined,
            .polygon_count = 0,
            .is_drawing_polygon = false,
            .delay_seconds = 0,
            .delay_countdown = 0,
            .capture_scheduled = false,
            .captured_image = cap[0..0],
            .captured_width = 0,
            .captured_height = 0,
            .has_capture = false,
            .caption_hover = .none,
            .hover_new = false,
            .hover_mode = 1,
            .hover_delay = 0,
            .hover_send = false,
            .preview_scroll_x = 0,
            .instruction_page = 0,
        };
    }

    /// Start a new snip capture
    pub fn startCapture(st: *SnippingTool) void {
        st.is_capturing = true;
        st.capture_in_progress = true;
        st.has_capture = false;
        st.polygon_count = 0;
        st.is_drawing_polygon = false;
        st.start_x = 0;
        st.start_y = 0;
        st.end_x = 0;
        st.end_y = 0;

        // If mode is full_screen, capture immediately
        if (st.mode == .full_screen) {
            st.captureFullScreen();
        }
    }

    /// Set rectangular selection region
    pub fn setCaptureRegion(st: *SnippingTool, x1: i32, y1: i32, x2: i32, y2: i32) void {
        st.start_x = x1;
        st.start_y = y1;
        st.end_x = x2;
        st.end_y = y2;
    }

    /// Add point to freeform polygon
    pub fn addPolygonPoint(st: *SnippingTool, x: i32, y: i32) void {
        if (st.polygon_count < MAX_POLYGON_POINTS) {
            st.polygon_points[st.polygon_count] = .{ .x = x, .y = y };
            st.polygon_count += 1;
        }
    }

    /// End polygon drawing and capture
    pub fn endPolygonCapture(st: *SnippingTool) void {
        if (st.polygon_count >= 3) {
            st.capturePolygonRegion();
        }
        st.is_drawing_polygon = false;
        st.polygon_count = 0;
    }

    /// Capture full screen
    fn captureFullScreen(st: *SnippingTool) void {
        // Full screen capture would use the entire framebuffer
        // For now, mark as complete
        st.capture_in_progress = false;
        st.has_capture = true;
    }

    /// Capture rectangular region
    fn captureRectRegion(st: *SnippingTool) void {
        const x0 = @min(st.start_x, st.end_x);
        const y0 = @min(st.start_y, st.end_y);
        const x1 = @max(st.start_x, st.end_x);
        const y1 = @max(st.start_y, st.end_y);
        var rw = x1 - x0;
        var rh = y1 - y0;

        if (rw <= 0 or rh <= 0) {
            st.capture_in_progress = false;
            return;
        }

        const max_w: i32 = 640;
        const max_h: i32 = 480;
        if (rw > max_w) rw = max_w;
        if (rh > max_h) rh = max_h;

        var buf: [640 * 480 * 4]u8 = undefined;
        const n = fb.copyDrawBufferRectBytes(x0, y0, rw, rh, &buf);
        if (n > 0) {
            // Copy to captured buffer
            @memcpy(st.captured_image[0..n], buf[0..n]);
            st.captured_width = @intCast(rw);
            st.captured_height = @intCast(rh);
            st.has_capture = true;

            // Copy to clipboard
            builtin_apps.getClipboard().setDibBgr32(@intCast(rw), @intCast(rh), buf[0..n]);
        }
        st.capture_in_progress = false;
    }

    /// Capture polygon region (simplified - uses bounding box)
    fn capturePolygonRegion(st: *SnippingTool) void {
        if (st.polygon_count < 3) {
            st.capture_in_progress = false;
            return;
        }

        // Find bounding box
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);

        for (st.polygon_points[0..st.polygon_count]) |pt| {
            if (pt.x < min_x) min_x = pt.x;
            if (pt.y < min_y) min_y = pt.y;
            if (pt.x > max_x) max_x = pt.x;
            if (pt.y > max_y) max_y = pt.y;
        }

        const rw = max_x - min_x;
        const rh = max_y - min_y;

        if (rw <= 0 or rh <= 0) {
            st.capture_in_progress = false;
            return;
        }

        const max_w: i32 = 640;
        const max_h: i32 = 480;
        const cap_w: i32 = @min(rw, max_w);
        const cap_h: i32 = @min(rh, max_h);

        var buf: [640 * 480 * 4]u8 = undefined;
        const n = fb.copyDrawBufferRectBytes(min_x, min_y, cap_w, cap_h, &buf);
        if (n > 0) {
            @memcpy(st.captured_image[0..n], buf[0..n]);
            st.captured_width = @intCast(cap_w);
            st.captured_height = @intCast(cap_h);
            st.has_capture = true;
            builtin_apps.getClipboard().setDibBgr32(@intCast(cap_w), @intCast(cap_h), buf[0..n]);
        }
        st.capture_in_progress = false;
    }

    /// End capture
    pub fn endCapture(st: *SnippingTool) void {
        st.is_capturing = false;

        if (st.capture_in_progress) {
            switch (st.mode) {
                .rectangular => st.captureRectRegion(),
                .freeform => st.endPolygonCapture(),
                .window => st.captureWindowRegion(),
                .full_screen => {},
            }
        }
    }

    /// Capture window region (placeholder)
    fn captureWindowRegion(st: *SnippingTool) void {
        // TODO: implement window region capture
        st.capture_in_progress = false;
        st.has_capture = true;
    }

    /// Schedule delayed capture
    pub fn scheduleDelayedCapture(st: *SnippingTool, delay: u8) void {
        if (delay > MAX_DELAY_SECONDS) {
            st.delay_seconds = MAX_DELAY_SECONDS;
        } else {
            st.delay_seconds = delay;
        }
        st.delay_countdown = @as(i32, @intCast(st.delay_seconds));
        st.capture_scheduled = true;
    }

    /// Update delay countdown
    pub fn tickDelay(st: *SnippingTool) void {
        if (st.capture_scheduled and st.delay_countdown > 0) {
            st.delay_countdown -= 1;
            if (st.delay_countdown <= 0) {
                st.capture_scheduled = false;
                st.startCapture();
            }
        }
    }

    /// Set snip mode
    pub fn setMode(st: *SnippingTool, mode: SnipMode) void {
        st.mode = mode;
    }

    /// Copy captured image to clipboard
    pub fn copyToClipboard(st: *SnippingTool) void {
        if (!st.has_capture) return;

        if (st.captured_width > 0 and st.captured_height > 0) {
            const n = @as(usize, st.captured_width) * @as(usize, st.captured_height) * 4;
            if (n <= st.captured_image.len) {
                builtin_apps.getClipboard().setDibBgr32(st.captured_width, st.captured_height, st.captured_image[0..n]);
            }
        }
    }

    /// Send/copy the captured image
    pub fn sendCapture(st: *SnippingTool) void {
        st.copyToClipboard();
    }

    /// Main render function
    pub fn render(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        if (!st.visible) return;

        // Tick delay timer
        st.tickDelay();

        st.renderWindow(t);
        st.renderToolbar(t);
        st.renderDelayOptions(t);

        if (st.has_capture) {
            st.renderPreview(t);
        } else {
            st.renderInstructions(t);
        }

        // Render countdown overlay
        if (st.capture_scheduled) {
            st.renderCountdownOverlay(t);
        }
    }

    /// Render main window frame
    fn renderWindow(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = st.x;
        const wy = st.y;
        const ww = st.width;
        const wh = st.height;
        const ch: i32 = 32;

        // Window background
        fb.fillRect(wx, wy + ch, ww, wh - ch, rgb(0xF0, 0xF4, 0xF8));

        // Title bar with gradient
        fb.drawGradientH(wx, wy, ww, ch, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));

        // Title text
        fb.drawTextTransparent(wx + 8, wy + 6, "Snipping Tool", rgb(0xFF, 0xFF, 0xFF));

        // Close button
        const close_x = wx + ww - 48;
        if (st.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        // Window border
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    }

    /// Render toolbar with mode buttons
    fn renderToolbar(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const tx = st.x + 8;
        const ty = st.y + 40;
        const th: i32 = 36;

        // Toolbar background
        fb.fillRect(tx, ty, st.width - 16, th, rgb(0xEC, 0xEC, 0xEC));
        fb.draw3DRect(tx, ty, st.width - 16, th, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));

        // Mode buttons
        const modes = [_][]const u8{ "New", "Free-form", "Rectangular", "Window", "Full Screen" };
        var mode_x = tx + 8;
        for (modes, 0..) |mode_text, idx| {
            const is_new = idx == 0;
            const is_selected = !is_new and idx - 1 == st.hover_mode;
            const btn_w: i32 = 60;
            const btn_h: i32 = 28;

            if (is_new) {
                if (st.hover_new) {
                    fb.fillRect(mode_x, ty + 4, btn_w, btn_h, rgb(0xD0, 0xD8, 0xE8));
                    fb.draw3DRect(mode_x, ty + 4, btn_w, btn_h, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
                } else {
                    fb.fillRect(mode_x, ty + 4, btn_w, btn_h, rgb(0xE8, 0xEC, 0xF4));
                    fb.draw3DRect(mode_x, ty + 4, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
                }
                fb.drawTextTransparent(mode_x + 12, ty + 10, mode_text, rgb(0x20, 0x40, 0x90));
            } else {
                if (is_selected) {
                    fb.fillRect(mode_x, ty + 4, btn_w, btn_h, rgb(0xD0, 0xD8, 0xE8));
                    fb.draw3DRect(mode_x, ty + 4, btn_w, btn_h, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
                } else {
                    fb.fillRect(mode_x, ty + 4, btn_w, btn_h, rgb(0xF0, 0xF4, 0xF8));
                    fb.draw3DRect(mode_x, ty + 4, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
                }
                fb.drawTextTransparent(mode_x + 8, ty + 10, mode_text, rgb(0x30, 0x30, 0x40));
            }
            mode_x += btn_w + 4;
        }
    }

    /// Render delay options
    fn renderDelayOptions(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const dx = st.x + 8;
        const dy = st.y + 85;

        fb.drawTextTransparent(dx, dy, "Delay:", rgb(0x40, 0x40, 0x50));

        const delays = [_]u8{ 0, 3, 5 };
        var delay_x = dx + 50;
        for (delays, 0..) |delay_val, idx| {
            const is_selected = st.hover_delay == @as(i32, @intCast(idx));
            const bw: i32 = 50;
            const bh: i32 = 20;

            if (is_selected) {
                fb.fillRect(delay_x, dy - 2, bw, bh, rgb(0xD0, 0xD8, 0xE8));
                fb.draw3DRect(delay_x, dy - 2, bw, bh, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
            } else {
                fb.fillRect(delay_x, dy - 2, bw, bh, rgb(0xF0, 0xF4, 0xF8));
                fb.draw3DRect(delay_x, dy - 2, bw, bh, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
            }

            var label_buf: [16]u8 = undefined;
            const label_str = if (delay_val == 0) "None" else std.fmt.bufPrint(&label_buf, "{d}s", .{delay_val}) catch "?";
            fb.drawTextTransparent(delay_x + 8, dy + 2, label_str, rgb(0x30, 0x30, 0x40));
            delay_x += bw + 4;
        }
    }

    /// Render countdown overlay
    fn renderCountdownOverlay(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const cx = st.x + @divTrunc(st.width, 2);
        const cy = st.y + @divTrunc(st.height, 2);

        // Semi-transparent overlay
        fb.fillRect(st.x, st.y + 32, st.width, st.height - 32, rgb(0x00, 0x00, 0x00));

        // Countdown number
        var num_buf: [4]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{st.delay_countdown}) catch "0";

        // Large centered text
        fb.drawTextTransparent(cx - 20, cy - 20, num_str, rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(cx - 40, cy + 10, "seconds", rgb(0xCC, 0xCC, 0xCC));
    }

    /// Render instructions when no capture exists
    fn renderInstructions(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const ix = st.x + 16;
        const iy = st.y + 120;

        // Mode-specific instructions
        const mode_instructions = switch (st.mode) {
            .freeform => "Draw an irregular shape around the area.",
            .rectangular => "Drag the cursor to select a rectangular area.",
            .window => "Click on a window to capture it.",
            .full_screen => "Click New to capture the entire screen.",
        };

        fb.drawTextTransparent(ix, iy, mode_instructions, rgb(0x40, 0x40, 0x50));

        const mode_text = switch (st.mode) {
            .freeform => "Mode: Free-form Snip",
            .rectangular => "Mode: Rectangular Snip",
            .window => "Mode: Window Snip",
            .full_screen => "Mode: Full-screen Snip",
        };
        fb.drawTextTransparent(ix, iy + 24, mode_text, rgb(0x20, 0x40, 0x80));

        // Help text
        fb.drawTextTransparent(ix, iy + 60, "Tip: Press Esc to cancel capture.", rgb(0x80, 0x80, 0x90));
    }

    /// Render preview of captured image
    fn renderPreview(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const px = st.x + 16;
        const py = st.y + 115;
        const pw = st.width - 32;
        const ph: i32 = 180;

        // Preview container
        fb.fillRect(px, py, pw, ph, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(px, py, pw, ph, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF0));

        // Render captured image (scaled to fit preview)
        if (st.has_capture and st.captured_width > 0 and st.captured_height > 0) {
            const preview_max_w = pw - 10;
            const preview_max_h = ph - 40;

            const scale_x: f64 = @as(f64, @floatFromInt(preview_max_w)) / @as(f64, @floatFromInt(st.captured_width));
            const scale_y: f64 = @as(f64, @floatFromInt(preview_max_h)) / @as(f64, @floatFromInt(st.captured_height));
            const scale: f64 = @min(scale_x, scale_y);

            const scaled_w: i32 = @intFromFloat(@as(f64, @floatFromInt(st.captured_width)) * scale);
            const scaled_h: i32 = @intFromFloat(@as(f64, @floatFromInt(st.captured_height)) * scale);
            const img_x = px + 5 + @divTrunc(preview_max_w - scaled_w, 2);
            const img_y = py + 5 + @divTrunc(preview_max_h - scaled_h, 2);

            // Draw scaled image pixels
            var sy: i32 = 0;
            while (sy < scaled_h) : (sy += 1) {
                var sx: i32 = 0;
                while (sx < scaled_w) : (sx += 1) {
                    const src_x = @divTrunc(sx * @as(i32, @intCast(st.captured_width)), scaled_w);
                    const src_y = @divTrunc(sy * @as(i32, @intCast(st.captured_height)), scaled_h);
                    const src_idx = (@as(usize, @intCast(src_y)) * @as(usize, @intCast(st.captured_width)) + @as(usize, @intCast(src_x))) * 4;

                    if (src_idx + 3 < st.captured_image.len) {
                        const r = st.captured_image[src_idx + 2];
                        const g = st.captured_image[src_idx + 1];
                        const b = st.captured_image[src_idx];
                        fb.fillRect(img_x + sx, img_y + sy, 1, 1, rgb(r, g, b));
                    }
                }
            }
        } else {
            fb.drawTextTransparent(px + 10, py + @divTrunc(ph, 2), "No capture yet", rgb(0xA0, 0xA0, 0xA0));
        }

        // Image info
        var info_buf: [64]u8 = undefined;
        const info_str = if (st.has_capture)
            std.fmt.bufPrint(&info_buf, "{d} x {d}", .{ st.captured_width, st.captured_height }) catch "?"
        else
            "No image";
        fb.drawTextTransparent(px + 4, py + ph - 16, info_str, rgb(0x60, 0x60, 0x60));

        // Send button
        const send_x = px + pw - 70;
        const send_y = py + ph - 30;
        if (st.hover_send) {
            fb.fillRect(send_x, send_y, 65, 24, rgb(0xD0, 0xD8, 0xE8));
            fb.draw3DRect(send_x, send_y, 65, 24, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
        } else {
            fb.fillRect(send_x, send_y, 65, 24, rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(send_x, send_y, 65, 24, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
        }
        fb.drawTextTransparent(send_x + 12, send_y + 6, "Send", rgb(0x20, 0x40, 0x90));
    }
};
