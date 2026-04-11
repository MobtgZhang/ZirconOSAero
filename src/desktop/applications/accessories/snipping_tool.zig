// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/snipping_tool.zig
// Purpose: Windows 7 style Snipping Tool
//
// This is an independent clean-room implementation.

const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const SnipMode = enum {
    freeform,
    rectangular,
    window,
    full_screen,
};

pub const SnippingTool = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    focused: bool,
    mode: SnipMode,
    is_capturing: bool,
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
    captured_image: []u8,
    captured_width: u32,
    captured_height: u32,
    has_capture: bool,
    caption_hover: CaptionButtonType,
    hover_new: bool,
    hover_mode: i32,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create() SnippingTool {
        var cap: [640 * 480 * 4]u8 = undefined;
        return .{
            .x = 100, .y = 100,
            .width = 350, .height = 280,
            .visible = true,
            .focused = false,
            .mode = .rectangular,
            .is_capturing = false,
            .start_x = 0, .start_y = 0,
            .end_x = 0, .end_y = 0,
            .captured_image = cap[0..0],
            .captured_width = 0,
            .captured_height = 0,
            .has_capture = false,
            .caption_hover = .none,
            .hover_new = false,
            .hover_mode = 1,
        };
    }

    pub fn startCapture(st: *SnippingTool) void {
        st.is_capturing = true;
        st.has_capture = false;
    }

    pub fn setCaptureRegion(st: *SnippingTool, x1: i32, y1: i32, x2: i32, y2: i32) void {
        st.start_x = x1;
        st.start_y = y1;
        st.end_x = x2;
        st.end_y = y2;
    }

    pub fn endCapture(st: *SnippingTool) void {
        st.is_capturing = false;
        st.has_capture = true;
    }

    pub fn setMode(st: *SnippingTool, mode: SnipMode) void {
        st.mode = mode;
    }

    pub fn copyToClipboard(st: *SnippingTool) void {
        _ = st;
    }

    pub fn render(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        if (!st.visible) return;
        st.renderWindow(t);
        st.renderToolbar(t);
        st.renderInstructions(t);
        if (st.has_capture) {
            st.renderPreview(t);
        }
    }

    fn renderWindow(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = st.x;
        const wy = st.y;
        const ww = st.width;
        const wh = st.height;
        const ch: i32 = 32;

        fb.fillRect(wx, wy + ch, ww, wh - ch, rgb(0xF0, 0xF4, 0xF8));

        const title_color = rgb(0x20, 0x40, 0x80);
        fb.drawTextTransparent(wx + 8, wy + 6, "Snipping Tool", title_color);

        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    }

    fn renderToolbar(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const tx = st.x + 8;
        const ty = st.y + 40;
        const th: i32 = 36;

        fb.fillRect(tx, ty, st.width - 16, th, rgb(0xEC, 0xEC, 0xEC));

        const modes = [_][]const u8{ "New", "Free-form", "Rectangular", "Window", "Full Screen" };
        var mode_x = tx + 8;
        for (modes, 0..) |mode_text, idx| {
            const is_new = idx == 0;
            const is_selected = !is_new and idx - 1 == st.hover_mode;
            const label = if (is_new) "New" else mode_text;

            if (is_new) {
                if (st.hover_new) {
                    fb.fillRect(mode_x, ty + 4, 50, 28, rgb(0xD0, 0xD8, 0xE8));
                    fb.draw3DRect(mode_x, ty + 4, 50, 28, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
                } else {
                    fb.fillRect(mode_x, ty + 4, 50, 28, rgb(0xE8, 0xEC, 0xF4));
                    fb.draw3DRect(mode_x, ty + 4, 50, 28, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
                }
                fb.drawTextTransparent(mode_x + 8, ty + 12, label, rgb(0x20, 0x40, 0x90));
            } else {
                if (is_selected) {
                    fb.fillRect(mode_x, ty + 4, 50, 28, rgb(0xD0, 0xD8, 0xE8));
                    fb.draw3DRect(mode_x, ty + 4, 50, 28, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
                } else {
                    fb.fillRect(mode_x, ty + 4, 50, 28, rgb(0xF0, 0xF4, 0xF8));
                    fb.draw3DRect(mode_x, ty + 4, 50, 28, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
                }
                fb.drawTextTransparent(mode_x + 4, ty + 12, label, rgb(0x30, 0x30, 0x40));
            }
            mode_x += 58;
        }
    }

    fn renderInstructions(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const ix = st.x + 16;
        const iy = st.y + 90;

        fb.drawTextTransparent(ix, iy, "Click New to start a snip.", rgb(0x40, 0x40, 0x50));
        fb.drawTextTransparent(ix, iy + 20, "Drag the cursor to select", rgb(0x40, 0x40, 0x50));
        fb.drawTextTransparent(ix, iy + 40, "an area to capture.", rgb(0x40, 0x40, 0x50));

        const mode_text = switch (st.mode) {
            .freeform => "Mode: Free-form Snip",
            .rectangular => "Mode: Rectangular Snip",
            .window => "Mode: Window Snip",
            .full_screen => "Mode: Full-screen Snip",
        };
        fb.drawTextTransparent(ix, iy + 70, mode_text, rgb(0x20, 0x40, 0x80));
    }

    fn renderPreview(st: *SnippingTool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const px = st.x + 16;
        const py = st.y + 160;
        const pw = st.width - 32;
        const ph: i32 = 80;

        fb.fillRect(px, py, pw, ph, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(px, py, pw, ph, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF0));

        fb.drawTextTransparent(px + 10, py + 30, "Preview area", rgb(0xA0, 0xA0, 0xA0));

        const send_x = px + pw - 80;
        fb.fillRect(send_x, py + ph - 30, 70, 24, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(send_x, py + ph - 30, 70, 24, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
        fb.drawTextTransparent(send_x + 15, py + ph - 24, "Send", rgb(0x20, 0x40, 0x90));
    }
};
