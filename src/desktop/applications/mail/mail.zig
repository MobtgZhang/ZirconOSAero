// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/mail/mail.zig
// Purpose: Windows Mail - Email client application
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const MailMessage = struct {
    id: u32,
    from: [64]u8,
    from_len: usize,
    subject: [128]u8,
    subject_len: usize,
    date: [32]u8,
    date_len: usize,
    preview: [256]u8,
    preview_len: usize,
    read: bool,
    starred: bool,
    has_attachment: bool,
};

pub const MailFolder = enum {
    inbox,
    sent,
    drafts,
    deleted,
    junk,
};

pub const MailView = enum {
    inbox,
    sent,
    compose,
    message_view,
};

pub const MailApp = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,

    current_view: MailView,
    messages: [50]MailMessage,
    message_count: usize,
    selected_message: i32,

    // Compose fields
    compose_to: [128]u8,
    compose_to_len: usize,
    compose_subject: [128]u8,
    compose_subject_len: usize,
    compose_body: [2048]u8,
    compose_body_len: usize,

    // UI state
    hover_inbox: bool,
    hover_sent: bool,
    hover_compose: bool,
    hover_refresh: bool,
    hover_star: bool,
    hover_delete: bool,

    // Navigation
    scroll_offset: i32,
    list_hover_index: i32,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) MailApp {
        var app: MailApp = .{
            .x = x_pos,
            .y = y_pos,
            .width = 700,
            .height = 500,
            .visible = true,
            .caption_hover = .none,
            .current_view = .inbox,
            .messages = undefined,
            .message_count = 0,
            .selected_message = -1,
            .compose_to = undefined,
            .compose_to_len = 0,
            .compose_subject = undefined,
            .compose_subject_len = 0,
            .compose_body = undefined,
            .compose_body_len = 0,
            .hover_inbox = false,
            .hover_sent = false,
            .hover_compose = false,
            .hover_refresh = false,
            .hover_star = false,
            .hover_delete = false,
            .scroll_offset = 0,
            .list_hover_index = -1,
        };

        app.initSampleMessages();
        return app;
    }

    fn initSampleMessages(app: *MailApp) void {
        // Sample inbox messages
        const samples = [_]struct { from: []const u8, subject: []const u8, preview: []const u8 }{
            .{ .from = "System Admin", .subject = "Welcome to ZirconOSAero Mail", .preview = "This is a sample message to demonstrate the mail application..." },
            .{ .from = "Newsletter", .subject = "Weekly Update", .preview = "Check out the latest news and updates from the team..." },
            .{ .from = "Notifications", .subject = "New Feature Available", .preview = "A new feature has been added to improve your experience..." },
            .{ .from = "Support", .subject = "Your ticket has been resolved", .preview = "Your support ticket #1234 has been resolved. Please review..." },
        };

        app.message_count = 0;
        for (samples, 0..) |s, i| {
            var msg = &app.messages[i];
            msg.id = @as(u32, @intCast(i));

            @memcpy(msg.from[0..s.from.len], s.from);
            msg.from_len = s.from.len;
            msg.from[msg.from_len] = 0;

            @memcpy(msg.subject[0..s.subject.len], s.subject);
            msg.subject_len = s.subject.len;
            msg.subject[msg.subject_len] = 0;

            @memcpy(msg.preview[0..s.preview.len], s.preview);
            msg.preview_len = s.preview.len;
            msg.preview[msg.preview_len] = 0;

            @memcpy(msg.date[0..5], "Apr 13");
            msg.date_len = 5;

            msg.read = (i % 2 == 0);
            msg.starred = (i == 1);
            msg.has_attachment = (i == 3);

            app.message_count += 1;
        }
    }

    pub fn render(app: *const MailApp, t: *const theme_mod.ThemeColors) void {
        if (!app.visible) return;
        _ = t;

        const wx = app.x;
        const wy = app.y;
        const ww = app.width;
        const wh = app.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 6, "Windows Mail", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (app.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        // Three-column layout
        const sidebar_w: i32 = 150;
        const list_w: i32 = 250;

        // Sidebar
        fb.fillRect(wx, wy + 32, sidebar_w, wh - 32, rgb(0xE8, 0xED, 0xF2));
        fb.drawRect(wx + sidebar_w, wy + 32, 1, wh - 32, rgb(0xCC, 0xCC, 0xCC));

        // Sidebar buttons
        const btn_x = wx + 10;
        var btn_y = wy + 50;

        // Compose button
        const compose_h: i32 = 36;
        const compose_bg = if (app.hover_compose) rgb(0x00, 0x78, 0xD4) else rgb(0x00, 0x68, 0xC4);
        fb.fillRect(btn_x, btn_y, sidebar_w - 20, compose_h, compose_bg);
        fb.drawTextTransparent(btn_x + 20, btn_y + 10, "+ Compose", rgb(0xFF, 0xFF, 0xFF));

        btn_y += compose_h + 20;

        // Inbox folder
        const inbox_bg = if (app.hover_inbox) rgb(0xD0, 0xDC, 0xE8) else if (app.current_view == .inbox) rgb(0xC0, 0xD0, 0xE0) else rgb(0xE8, 0xED, 0xF2);
        fb.fillRect(btn_x - 5, btn_y, sidebar_w - 10, 30, inbox_bg);
        fb.drawTextTransparent(btn_x + 5, btn_y + 8, "Inbox", rgb(0x20, 0x20, 0x30));
        var count_buf: [8]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "({d})", .{app.message_count}) catch "";
        fb.drawTextTransparent(btn_x + 80, btn_y + 8, count_str, rgb(0x80, 0x80, 0x90));

        btn_y += 35;

        // Sent folder
        const sent_bg = if (app.hover_sent) rgb(0xD0, 0xDC, 0xE8) else rgb(0xE8, 0xED, 0xF2);
        fb.fillRect(btn_x - 5, btn_y, sidebar_w - 10, 30, sent_bg);
        fb.drawTextTransparent(btn_x + 5, btn_y + 8, "Sent", rgb(0x20, 0x20, 0x30));

        // Message list
        fb.fillRect(wx + sidebar_w, wy + 32, list_w, wh - 32, rgb(0xFF, 0xFF, 0xFF));
        fb.drawRect(wx + sidebar_w + list_w, wy + 32, 1, wh - 32, rgb(0xCC, 0xCC, 0xCC));

        // List header
        const header_y = wy + 32;
        fb.fillRect(wx + sidebar_w, header_y, list_w, 30, rgb(0xF5, 0xF5, 0xF5));
        fb.drawTextTransparent(wx + sidebar_w + 10, header_y + 8, "Inbox", rgb(0x20, 0x20, 0x30));

        // Refresh button
        const refresh_bg = if (app.hover_refresh) rgb(0xE0, 0xE0, 0xE0) else rgb(0xF0, 0xF0, 0xF0);
        fb.fillRect(wx + sidebar_w + list_w - 35, header_y + 3, 28, 24, refresh_bg);
        fb.draw3DRect(wx + sidebar_w + list_w - 35, header_y + 3, 28, 24, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(wx + sidebar_w + list_w - 28, header_y + 8, "R", rgb(0x40, 0x40, 0x50));

        // Message list items
        const list_start_y = header_y + 30;
        const item_h: i32 = 70;

        for (0..app.message_count) |i| {
            const item_y = list_start_y + @as(i32, @intCast(i)) * item_h - app.scroll_offset;
            if (item_y < list_start_y or item_y > wy + wh - 60) continue;

            const msg = app.messages[i];
            const is_selected = @as(i32, @intCast(i)) == app.selected_message;
            const is_hover = @as(i32, @intCast(i)) == app.list_hover_index;

            // Item background
            var item_bg = rgb(0xFF, 0xFF, 0xFF);
            if (is_selected) {
                item_bg = rgb(0xD8, 0xE8, 0xF8);
            } else if (is_hover) {
                item_bg = rgb(0xF0, 0xF5, 0xFA);
            }
            fb.fillRect(wx + sidebar_w + 1, item_y, list_w - 1, item_h - 1, item_bg);
            fb.drawHLine(wx + sidebar_w, item_y + item_h, list_w, rgb(0xE0, 0xE0, 0xE0));

            // Read indicator
            if (!msg.read) {
                fb.fillRect(wx + sidebar_w + 5, item_y + 8, 8, 8, rgb(0x00, 0x78, 0xD4));
            }

            // Star
            const star_color = if (msg.starred) rgb(0xFF, 0xC0, 0x00) else rgb(0xC0, 0xC0, 0xC0);
            fb.drawTextTransparent(wx + sidebar_w + 20, item_y + 5, if (msg.starred) "*" else "-", star_color);

            // From
            const from_text = msg.from[0..msg.from_len];
            const from_color = if (msg.read) rgb(0x60, 0x60, 0x60) else rgb(0x10, 0x10, 0x10);
            fb.drawTextTransparent(wx + sidebar_w + 35, item_y + 5, from_text, from_color);

            // Date
            fb.drawTextTransparent(wx + sidebar_w + list_w - 55, item_y + 5, msg.date[0..msg.date_len], rgb(0x80, 0x80, 0x80));

            // Subject
            fb.drawTextTransparent(wx + sidebar_w + 35, item_y + 22, msg.subject[0..msg.subject_len], if (msg.read) rgb(0x50, 0x50, 0x50) else rgb(0x20, 0x20, 0x30));

            // Preview
            fb.drawTextTransparent(wx + sidebar_w + 35, item_y + 38, msg.preview[0..@min(msg.preview_len, 40)], rgb(0x80, 0x80, 0x80));

            // Attachment indicator
            if (msg.has_attachment) {
                fb.drawTextTransparent(wx + sidebar_w + list_w - 40, item_y + 40, "[!]", rgb(0x80, 0x60, 0x40));
            }
        }

        // Preview pane / Content area
        const content_x = wx + sidebar_w + list_w + 1;
        const content_w = ww - sidebar_w - list_w - 1;

        fb.fillRect(content_x, wy + 32, content_w, wh - 32, rgb(0xFF, 0xFF, 0xFF));

        if (app.current_view == .compose) {
            app.renderComposePane(content_x, wy + 32, content_w, wh - 32);
        } else if (app.selected_message >= 0) {
            const idx = @as(usize, @intCast(app.selected_message));
            if (idx < app.message_count) {
                app.renderMessagePane(content_x, wy + 32, content_w, wh - 32, app.messages[idx]);
            }
        } else {
            // Empty state
            fb.drawTextTransparent(content_x + content_w / 2 - 100, wy + wh / 2 - 20, "Select a message to read", rgb(0xA0, 0xA0, 0xA0));
        }
    }

    fn renderComposePane(app: *const MailApp, x: i32, y: i32, w: i32, h: i32) void {
        fb.fillRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));

        // Header
        fb.drawTextTransparent(x + 10, y + 15, "New Message", rgb(0x20, 0x20, 0x30));
        fb.drawHLine(x, y + 40, w, rgb(0xE0, 0xE0, 0xE0));

        // To field
        fb.drawTextTransparent(x + 10, y + 50, "To:", rgb(0x50, 0x50, 0x60));
        fb.fillRect(x + 50, y + 48, w - 70, 24, rgb(0xF8, 0xF8, 0xF8));
        fb.drawRect(x + 50, y + 48, w - 70, 24, rgb(0xC0, 0xC0, 0xC0));
        if (app.compose_to_len > 0) {
            fb.drawTextTransparent(x + 55, y + 54, app.compose_to[0..app.compose_to_len], rgb(0x20, 0x20, 0x20));
        }

        // Subject field
        fb.drawTextTransparent(x + 10, y + 82, "Subject:", rgb(0x50, 0x50, 0x60));
        fb.fillRect(x + 70, y + 80, w - 90, 24, rgb(0xF8, 0xF8, 0xF8));
        fb.drawRect(x + 70, y + 80, w - 90, 24, rgb(0xC0, 0xC0, 0xC0));
        if (app.compose_subject_len > 0) {
            fb.drawTextTransparent(x + 75, y + 86, app.compose_subject[0..app.compose_subject_len], rgb(0x20, 0x20, 0x20));
        }

        fb.drawHLine(x, y + 115, w, rgb(0xE0, 0xE0, 0xE0));

        // Body
        fb.fillRect(x + 5, y + 120, w - 10, h - 180, rgb(0xFF, 0xFF, 0xFF));
        if (app.compose_body_len > 0) {
            var iy = y + 130;
            var i: usize = 0;
            while (i < app.compose_body_len and iy < y + h - 60) : (i += 1) {
                if (app.compose_body[i] == '\n') {
                    iy += 14;
                    continue;
                }
                if (i % 80 == 0 and i > 0) {
                    iy += 14;
                }
                fb.drawTextTransparent(x + 10, iy, app.compose_body[i..@min(i + 80, app.compose_body_len)], rgb(0x20, 0x20, 0x20));
                break;
            }
        }

        // Action buttons
        const btn_y = y + h - 50;
        const btn_w: i32 = 80;
        const btn_h: i32 = 30;

        fb.fillRect(x + w - btn_w - 10, btn_y, btn_w, btn_h, rgb(0x00, 0x68, 0xC4));
        fb.draw3DRect(x + w - btn_w - 10, btn_y, btn_w, btn_h, rgb(0x00, 0x50, 0xA0), rgb(0x40, 0x90, 0xE4));
        fb.drawTextTransparent(x + w - btn_w + 20, btn_y + 8, "Send", rgb(0xFF, 0xFF, 0xFF));

        fb.fillRect(x + w - 2 * btn_w - 20, btn_y, btn_w, btn_h, rgb(0xE0, 0xE0, 0xE0));
        fb.draw3DRect(x + w - 2 * btn_w - 20, btn_y, btn_w, btn_h, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(x + w - 2 * btn_w - 5, btn_y + 8, "Discard", rgb(0x40, 0x40, 0x50));
    }

    fn renderMessagePane(app: *const MailApp, x: i32, y: i32, w: i32, h: i32, msg: MailMessage) void {
        _ = app;

        fb.fillRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));

        // Header
        fb.drawTextTransparent(x + 10, y + 15, msg.subject[0..msg.subject_len], rgb(0x10, 0x10, 0x20));
        fb.drawHLine(x, y + 40, w, rgb(0xE0, 0xE0, 0xE0));

        // From/Date
        fb.drawTextTransparent(x + 10, y + 50, "From:", rgb(0x60, 0x60, 0x70));
        fb.drawTextTransparent(x + 60, y + 50, msg.from[0..msg.from_len], rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(x + w - 80, y + 50, msg.date[0..msg.date_len], rgb(0x80, 0x80, 0x90));

        // To
        fb.drawTextTransparent(x + 10, y + 70, "To:", rgb(0x60, 0x60, 0x70));
        fb.drawTextTransparent(x + 60, y + 70, "User", rgb(0x20, 0x20, 0x30));

        fb.drawHLine(x, y + 95, w, rgb(0xE0, 0xE0, 0xE0));

        // Body
        var body_y = y + 110;
        fb.drawTextTransparent(x + 10, body_y, msg.preview[0..msg.preview_len], rgb(0x20, 0x20, 0x30));
        body_y += 30;
        fb.drawTextTransparent(x + 10, body_y, "This is a sample email message. In a full implementation,", rgb(0x40, 0x40, 0x40));
        body_y += 14;
        fb.drawTextTransparent(x + 10, body_y, "this would display the complete email content.", rgb(0x40, 0x40, 0x40));

        // Action buttons
        const btn_y = y + h - 50;

        // Reply button
        fb.fillRect(x + 10, btn_y, 70, 30, rgb(0xE0, 0xE0, 0xE0));
        fb.draw3DRect(x + 10, btn_y, 70, 30, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(x + 22, btn_y + 8, "Reply", rgb(0x40, 0x40, 0x50));

        // Forward button
        fb.fillRect(x + 90, btn_y, 70, 30, rgb(0xE0, 0xE0, 0xE0));
        fb.draw3DRect(x + 90, btn_y, 70, 30, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(x + 100, btn_y + 8, "Forward", rgb(0x40, 0x40, 0x50));

        // Delete button
        fb.fillRect(x + w - 80, btn_y, 70, 30, rgb(0xD0, 0x40, 0x40));
        fb.draw3DRect(x + w - 80, btn_y, 70, 30, rgb(0xB0, 0x20, 0x20), rgb(0xF0, 0x80, 0x80));
        fb.drawTextTransparent(x + w - 65, btn_y + 8, "Delete", rgb(0xFF, 0xFF, 0xFF));
    }

    pub fn handleMouseMove(app: *MailApp, px: i32, py: i32) void {
        const wx = app.x;
        const wy = app.y;

        const sidebar_w: i32 = 150;
        const list_w: i32 = 250;

        // Sidebar hover
        if (px >= wx and px < wx + sidebar_w) {
            app.hover_compose = (py >= wy + 50 and py < wy + 86);
            app.hover_inbox = (py >= wy + 106 and py < wy + 136);
            app.hover_sent = (py >= wy + 141 and py < wy + 171);
        } else {
            app.hover_compose = false;
            app.hover_inbox = false;
            app.hover_sent = false;
        }

        // List hover
        const header_y = wy + 62;
        const item_h: i32 = 70;
        if (px >= wx + sidebar_w and px < wx + sidebar_w + list_w and
            py >= header_y and py < wy + app.height - 60)
        {
            app.list_hover_index = @divTrunc(py - header_y + app.scroll_offset, item_h);
            if (app.list_hover_index < 0) app.list_hover_index = -1;
            if (@as(usize, @intCast(app.list_hover_index)) >= app.message_count) {
                app.list_hover_index = -1;
            }
        } else {
            app.list_hover_index = -1;
        }
    }

    pub fn handleClick(app: *MailApp, px: i32, py: i32) void {
        const wx = app.x;
        const wy = app.y;
        const wh = app.height;

        const sidebar_w: i32 = 150;
        const list_w: i32 = 250;

        // Sidebar clicks
        if (px >= wx and px < wx + sidebar_w) {
            if (py >= wy + 50 and py < wy + 86) {
                app.current_view = .compose;
                app.selected_message = -1;
            } else if (py >= wy + 106 and py < wy + 136) {
                app.current_view = .inbox;
                app.selected_message = -1;
            } else if (py >= wy + 141 and py < wy + 171) {
                app.current_view = .sent;
            }
            return;
        }

        // Message list clicks
        const header_y = wy + 62;
        const item_h: i32 = 70;
        if (px >= wx + sidebar_w and px < wx + sidebar_w + list_w and
            py >= header_y and py < wy + wh - 60)
        {
            const clicked_idx = @divTrunc(py - header_y + app.scroll_offset, item_h);
            if (clicked_idx >= 0 and @as(usize, @intCast(clicked_idx)) < app.message_count) {
                app.selected_message = clicked_idx;
                app.current_view = .message_view;
                app.messages[@as(usize, @intCast(clicked_idx))].read = true;
            }
            return;
        }
    }
};
