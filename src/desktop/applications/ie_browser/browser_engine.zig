// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/ie_browser/browser_engine.zig
// Purpose: Lightweight WebView engine for HTML content rendering
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

/// Maximum HTML document size
pub const MaxDocSize: usize = 65536;
pub const MaxUrlLen: usize = 2048;
pub const MaxHistory: usize = 50;

/// Callback types for browser events
pub const BrowserCallback = *const fn (*BrowserEngine, []const u8) void;

pub const BrowserEngine = struct {
    current_url: [MaxUrlLen]u8,
    current_url_len: usize,
    current_title: [256]u8,
    current_title_len: usize,
    is_loading: bool,
    load_progress: i32,
    can_go_back: bool,
    can_go_forward: bool,
    zoom_level: i32,

    // History
    history_back: [MaxHistory][MaxUrlLen]u8,
    history_back_len: [MaxHistory]usize,
    history_forward: [MaxHistory][MaxUrlLen]u8,
    history_forward_len: [MaxHistory]usize,
    back_count: usize,
    forward_count: usize,

    // Document content
    html_content: [MaxDocSize]u8,
    html_len: usize,

    // Render area
    viewport_x: i32,
    viewport_y: i32,
    viewport_w: i32,
    viewport_h: i32,

    // Callbacks
    on_url_change: ?*const fn (*BrowserEngine, []const u8) void,
    on_title_change: ?*const fn (*BrowserEngine, []const u8) void,
    on_progress_change: ?*const fn (*BrowserEngine, i32) void,
    on_load_complete: ?*const fn (*BrowserEngine) void,

    pub fn create(vx: i32, vy: i32, vw: i32, vh: i32) BrowserEngine {
        return .{
            .current_url = undefined,
            .current_url_len = 0,
            .current_title = undefined,
            .current_title_len = 0,
            .is_loading = false,
            .load_progress = 100,
            .can_go_back = false,
            .can_go_forward = false,
            .zoom_level = 100,
            .history_back = undefined,
            .history_back_len = undefined,
            .history_forward = undefined,
            .history_forward_len = undefined,
            .back_count = 0,
            .forward_count = 0,
            .html_content = undefined,
            .html_len = 0,
            .viewport_x = vx,
            .viewport_y = vy,
            .viewport_w = vw,
            .viewport_h = vh,
            .on_url_change = null,
            .on_title_change = null,
            .on_load_complete = null,
            .on_progress_change = null,
        };
    }

    pub fn loadUrl(be: *BrowserEngine, url: []const u8) void {
        // Save current page to back history
        if (be.current_url_len > 0) {
            if (be.back_count < MaxHistory) {
                @memcpy(&be.history_back[be.back_count], &be.current_url);
                be.history_back_len[be.back_count] = be.current_url_len;
                be.back_count += 1;
            }
            // Clear forward history on new navigation
            be.forward_count = 0;
        }

        // Set new URL
        be.current_url_len = @min(url.len, MaxUrlLen - 1);
        @memcpy(&be.current_url, url[0..be.current_url_len]);
        be.current_url[be.current_url_len] = 0;

        // Trigger URL change callback
        if (be.on_url_change) |cb| {
            cb(be, be.current_url[0..be.current_url_len]);
        }

        be.is_loading = true;
        be.load_progress = 0;

        // Simulate loading - in a real impl this would fetch from network
        be.simulatePageLoad();
    }

    fn simulatePageLoad(be: *BrowserEngine) void {
        // Build a simple HTML page from URL
        be.html_len = 0;

        var title_buf: [256]u8 = undefined;
        const title_text = std.fmt.bufPrint(&title_buf, "ZirconOSAero — {s}", .{be.current_url[0..be.current_url_len]}) catch be.current_url[0..be.current_url_len];
        const title_len = if (title_text.len < be.current_title.len) title_text.len else be.current_title.len;
        @memcpy(&be.current_title, title_text[0..title_len]);
        be.current_title_len = title_len;

        if (be.on_title_change) |cb| {
            cb(be, title_len);
        }

        be.is_loading = false;
        be.load_progress = 100;
        be.can_go_back = be.back_count > 0;
        be.can_go_forward = be.forward_count > 0;

        if (be.on_progress_change) |cb| {
            cb(be, 100);
        }
        if (be.on_load_complete) |cb| {
            cb(be);
        }
    }

    pub fn goBack(be: *BrowserEngine) bool {
        if (be.back_count == 0) return false;

        // Save current to forward history
        if (be.current_url_len > 0) {
            if (be.forward_count < MaxHistory) {
                @memcpy(&be.history_forward[be.forward_count], &be.current_url);
                be.history_forward_len[be.forward_count] = be.current_url_len;
                be.forward_count += 1;
            }
        }

        be.back_count -= 1;
        be.current_url_len = be.history_back_len[be.back_count];
        @memcpy(&be.current_url, &be.history_back[be.back_count]);
        be.current_url[be.current_url_len] = 0;

        be.can_go_back = be.back_count > 0;
        be.can_go_forward = true;

        if (be.on_url_change) |cb| {
            cb(be, be.current_url[0..be.current_url_len]);
        }

        be.load_progress = 100;
        if (be.on_progress_change) |cb| {
            cb(be, 100);
        }
        return true;
    }

    pub fn goForward(be: *BrowserEngine) bool {
        if (be.forward_count == 0) return false;

        // Save current to back history
        if (be.current_url_len > 0) {
            if (be.back_count < MaxHistory) {
                @memcpy(&be.history_back[be.back_count], &be.current_url);
                be.history_back_len[be.back_count] = be.current_url_len;
                be.back_count += 1;
            }
        }

        be.forward_count -= 1;
        be.current_url_len = be.history_forward_len[be.forward_count];
        @memcpy(&be.current_url, &be.history_forward[be.forward_count]);
        be.current_url[be.current_url_len] = 0;

        be.can_go_forward = be.forward_count > 0;
        be.can_go_back = true;

        if (be.on_url_change) |cb| {
            cb(be, be.current_url[0..be.current_url_len]);
        }

        be.load_progress = 100;
        if (be.on_progress_change) |cb| {
            cb(be, 100);
        }
        return true;
    }

    pub fn reload(be: *BrowserEngine) void {
        if (be.current_url_len > 0) {
            be.loadUrl(be.current_url[0..be.current_url_len]);
        }
    }

    pub fn stop(be: *BrowserEngine) void {
        be.is_loading = false;
        be.load_progress = 0;
    }

    pub fn getCurrentUrl(be: *const BrowserEngine) []const u8 {
        return be.current_url[0..be.current_url_len];
    }

    pub fn getCurrentTitle(be: *const BrowserEngine) []const u8 {
        return be.current_title[0..be.current_title_len];
    }

    pub fn canGoBack(be: *const BrowserEngine) bool {
        return be.can_go_back;
    }

    pub fn canGoForward(be: *const BrowserEngine) bool {
        return be.can_go_forward;
    }

    pub fn setOnUrlChange(be: *BrowserEngine, cb: *const fn (*BrowserEngine, []const u8) void) void {
        be.on_url_change = cb;
    }

    pub fn setOnTitleChange(be: *BrowserEngine, cb: *const fn (*BrowserEngine, []const u8) void) void {
        be.on_title_change = cb;
    }

    pub fn setOnProgressChange(be: *BrowserEngine, cb: *const fn (*BrowserEngine, i32) void) void {
        be.on_progress_change = cb;
    }

    pub fn setOnLoadComplete(be: *BrowserEngine, cb: *const fn (*BrowserEngine) void) void {
        be.on_load_complete = cb;
    }

    pub fn setZoom(be: *BrowserEngine, level: i32) void {
        be.zoom_level = @max(25, @min(500, level));
    }

    pub fn zoomIn(be: *BrowserEngine) void {
        be.setZoom(be.zoom_level + 10);
    }

    pub fn zoomOut(be: *BrowserEngine) void {
        be.setZoom(be.zoom_level - 10);
    }

    pub fn render(be: *BrowserEngine) void {
        // Background
        fb.fillRect(be.viewport_x, be.viewport_y, be.viewport_w, be.viewport_h, rgb(0xFF, 0xFF, 0xFF));

        const cx = be.viewport_x + 20;
        var cy = be.viewport_y + 20;

        // Title
        if (be.current_title_len > 0) {
            fb.drawTextTransparent(cx, cy, be.current_title[0..be.current_title_len], rgb(0x20, 0x20, 0x40));
            cy += 24;
        }

        // URL
        const url_display = be.current_url[0..be.current_url_len];
        if (url_display.len > 0) {
            fb.drawTextTransparent(cx, cy, url_display, rgb(0x00, 0x00, 0xCC));
            cy += 20;
        }

        // Separator
        fb.drawHLine(be.viewport_x, cy + 4, be.viewport_w, rgb(0xD0, 0xD8, 0xE0));
        cy += 16;

        // Content area - render simple page placeholder
        const content_x = be.viewport_x + 20;
        const content_y = cy;

        // Navigation info
        var info_buf: [128]u8 = undefined;
        const info1 = std.fmt.bufPrint(&info_buf, "Back: {s} | Forward: {s}", .{
            if (be.can_go_back) "Yes" else "No",
            if (be.can_go_forward) "Yes" else "No",
        }) catch "";

        if (info1.len > 0) {
            fb.drawTextTransparent(content_x, content_y, info1, rgb(0x40, 0x40, 0x60));
        }

        // Loading indicator
        if (be.is_loading) {
            const bar_x = be.viewport_x + 20;
            const bar_y = content_y + 30;
            const bar_w = be.viewport_w - 40;
            const bar_h = 8;

            fb.draw3DRect(bar_x, bar_y, bar_w, bar_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            const fill_w = @as(i32, @intCast(@as(f32, @floatFromInt(bar_w - 4)) * @as(f32, @floatFromInt(be.load_progress)) / 100.0));
            if (fill_w > 0) {
                fb.fillRect(bar_x + 2, bar_y + 2, fill_w, bar_h - 4, rgb(0x38, 0x78, 0x38));
            }
            fb.drawTextTransparent(bar_x + @divTrunc(bar_w, 2) - 20, bar_y - 16, "Loading...", rgb(0x60, 0x60, 0x80));
        }

        // Zoom level
        var zoom_buf: [32]u8 = undefined;
        const zoom_text = std.fmt.bufPrint(&zoom_buf, "Zoom: {d}%", .{be.zoom_level}) catch "";
        fb.drawTextTransparent(be.viewport_x + be.viewport_w - 80, be.viewport_y + 8, zoom_text, rgb(0x60, 0x60, 0x80));
    }

    pub fn setViewport(be: *BrowserEngine, vx: i32, vy: i32, vw: i32, vh: i32) void {
        be.viewport_x = vx;
        be.viewport_y = vy;
        be.viewport_w = vw;
        be.viewport_h = vh;
    }
};
