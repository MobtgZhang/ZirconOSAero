// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/wordpad.zig
// Purpose: WordPad - Rich Text Editor with RTF support
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

/// Rich text format control codes (subset)
pub const RTFTag = enum {
    bold_on,
    bold_off,
    italic_on,
    italic_off,
    underline_on,
    underline_off,
    font_size_8,
    font_size_10,
    font_size_12,
    font_size_14,
    font_size_18,
    font_size_24,
    color_red,
    color_blue,
    color_green,
    color_black,
};

/// Font family options
pub const FontFamily = enum(u8) { 
    arial = 0, 
    times = 1, 
    courier = 2, 
    segoe = 3,
    calibri = 4,
};

/// Text alignment
pub const TextAlignment = enum(u8) { left, center, right, justify };

/// WordPad window with enhanced formatting
pub const WordPadWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    
    // Text content with formatting
    text_content: [8192]u8,
    text_len: usize,
    
    // RTF content buffer
    rtf_content: [16384]u8,
    rtf_len: usize,
    
    // Cursor position
    cursor_x: i32,
    cursor_y: i32,
    
    // Scroll
    scroll_offset: i32,
    scroll_max: i32,
    
    // Formatting state
    toolbar_state: ToolbarState,
    format_bold: bool,
    format_italic: bool,
    format_underline: bool,
    format_font_size: i32,
    format_font_family: FontFamily,
    format_color: u32,
    format_alignment: TextAlignment,
    
    // Text attributes (per-character)
    text_attrs: [4096]TextAttr,
    attr_count: usize,
    
    // File state
    modified: bool,
    file_name: [256]u8,
    file_name_len: usize,
    is_rtf: bool,
    
    // UI state
    active_menu: MenuType,
    hover_menu_item: i32,
    hover_toolbar: i32,
    
    // Print preview
    print_preview: bool,
    preview_page: u32,
    total_pages: u32,
    
    // Dialog state
    show_font_dialog: bool,
    font_dialog_hover: i32,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const ToolbarState = struct {
        bold: bool,
        italic: bool,
        underline: bool,
        font_size: i32,
        font_family: FontFamily,
        alignment: TextAlignment,
    };
    pub const MenuType = enum { none, file, edit, view, insert, format, help };
    pub const TextAttr = struct {
        bold: bool,
        italic: bool,
        underline: bool,
        font_size: i32,
        color: u32,
    };

    pub fn create(x_pos: i32, y_pos: i32) WordPadWindow {
        return .{
            .x = x_pos,
            .y = y_pos,
            .width = 800,
            .height = 600,
            .visible = true,
            .caption_hover = .none,
            .text_content = undefined,
            .text_len = 0,
            .rtf_content = undefined,
            .rtf_len = 0,
            .cursor_x = 0,
            .cursor_y = 0,
            .scroll_offset = 0,
            .scroll_max = 0,
            .toolbar_state = .{
                .bold = false, 
                .italic = false, 
                .underline = false, 
                .font_size = 11,
                .font_family = .segoe,
                .alignment = .left,
            },
            .format_bold = false,
            .format_italic = false,
            .format_underline = false,
            .format_font_size = 11,
            .format_font_family = .segoe,
            .format_color = rgb(0x20, 0x20, 0x40),
            .format_alignment = .left,
            .text_attrs = undefined,
            .attr_count = 0,
            .modified = false,
            .file_name = undefined,
            .file_name_len = 0,
            .is_rtf = false,
            .active_menu = .none,
            .hover_menu_item = -1,
            .hover_toolbar = -1,
            .print_preview = false,
            .preview_page = 1,
            .total_pages = 1,
            .show_font_dialog = false,
            .font_dialog_hover = -1,
        };
    }

    /// Insert text at cursor position
    pub fn insertText(wp: *WordPadWindow, text: []const u8) void {
        if (wp.text_len + text.len < wp.text_content.len) {
            @memcpy(wp.text_content[wp.text_len..][0..text.len], text);
            wp.text_len += text.len;
            wp.modified = true;
            
            // Apply current formatting to new characters
            const attr = TextAttr{
                .bold = wp.format_bold,
                .italic = wp.format_italic,
                .underline = wp.format_underline,
                .font_size = wp.format_font_size,
                .color = wp.format_color,
            };
            
            for (0..text.len) |_| {
                if (wp.attr_count < wp.text_attrs.len) {
                    wp.text_attrs[wp.attr_count] = attr;
                    wp.attr_count += 1;
                }
            }
        }
    }

    /// Handle backspace
    pub fn backspace(wp: *WordPadWindow) void {
        if (wp.text_len > 0) {
            wp.text_len -= 1;
            if (wp.attr_count > 0) wp.attr_count -= 1;
            wp.modified = true;
        }
    }

    /// Toggle bold formatting
    pub fn toggleBold(wp: *WordPadWindow) void {
        wp.format_bold = !wp.format_bold;
        wp.toolbar_state.bold = wp.format_bold;
        wp.insertRTFTag(if (wp.format_bold) .bold_on else .bold_off);
    }

    /// Toggle italic formatting
    pub fn toggleItalic(wp: *WordPadWindow) void {
        wp.format_italic = !wp.format_italic;
        wp.toolbar_state.italic = wp.format_italic;
        wp.insertRTFTag(if (wp.format_italic) .italic_on else .italic_off);
    }

    /// Toggle underline formatting
    pub fn toggleUnderline(wp: *WordPadWindow) void {
        wp.format_underline = !wp.format_underline;
        wp.toolbar_state.underline = wp.format_underline;
        wp.insertRTFTag(if (wp.format_underline) .underline_on else .underline_off);
    }

    /// Set alignment
    pub fn setAlignment(wp: *WordPadWindow, alignment: TextAlignment) void {
        wp.format_alignment = alignment;
        wp.toolbar_state.alignment = alignment;
    }

    /// Set font size
    pub fn setFontSize(wp: *WordPadWindow, size: i32) void {
        wp.format_font_size = size;
        wp.toolbar_state.font_size = size;
        
        const tag: RTFTag = switch (size) {
            8 => .font_size_8,
            10 => .font_size_10,
            12 => .font_size_12,
            14 => .font_size_14,
            18 => .font_size_18,
            24 => .font_size_24,
            else => .font_size_12,
        };
        wp.insertRTFTag(tag);
    }

    /// Set font family
    pub fn setFontFamily(wp: *WordPadWindow, family: FontFamily) void {
        wp.format_font_family = family;
        wp.toolbar_state.font_family = family;
    }

    /// Set text color
    pub fn setColor(wp: *WordPadWindow, color: u32) void {
        wp.format_color = color;
        
        // Determine color tag based on RGB values
        const r = (color >> 16) & 0xFF;
        const g = (color >> 8) & 0xFF;
        const b = color & 0xFF;
        
        const tag: RTFTag = if (r > 128 and g < 64 and b < 64) .color_red
            else if (b > 128 and r < 64 and g < 64) .color_blue
            else if (g > 128 and r < 64 and b < 64) .color_green
            else .color_black;
        wp.insertRTFTag(tag);
    }

    /// Insert RTF formatting tag
    fn insertRTFTag(wp: *WordPadWindow, tag: RTFTag) void {
        const tag_str = switch (tag) {
            .bold_on => "\\b",
            .bold_off => "\\b0",
            .italic_on => "\\i",
            .italic_off => "\\i0",
            .underline_on => "\\ul",
            .underline_off => "\\ul0",
            .font_size_8 => "\\fs16",
            .font_size_10 => "\\fs20",
            .font_size_12 => "\\fs24",
            .font_size_14 => "\\fs28",
            .font_size_18 => "\\fs36",
            .font_size_24 => "\\fs48",
            .color_red => "\\cf1",
            .color_blue => "\\cf2",
            .color_green => "\\cf3",
            .color_black => "\\cf0",
        };
        
        // Append to RTF content
        if (wp.rtf_len + tag_str.len < wp.rtf_content.len) {
            @memcpy(wp.rtf_content[wp.rtf_len..][0..tag_str.len], tag_str);
            wp.rtf_len += tag_str.len;
        }
    }

    /// Convert text to RTF format
    pub fn toRTF(wp: *const WordPadWindow) []const u8 {
        var rtf: [16384]u8 = undefined;
        var pos: usize = 0;
        
        // RTF header
        const header = "{\\rtf1\\ansi\\deff0";
        @memcpy(rtf[pos..][0..header.len], header);
        pos += header.len;
        
        // Font table
        const font_table = "{\\fonttbl{\\f0\\froman Times New Roman;}{\\f1\\fswiss Arial;}{\\f2\\fmodern Courier New;}{\\f3\\fswiss Segoe UI;}}";
        if (pos + font_table.len < rtf.len) {
            @memcpy(rtf[pos..][0..font_table.len], font_table);
            pos += font_table.len;
        }
        
        // Color table
        const color_table = "{\\colortbl;\\red0\\green0\\blue0;\\red255\\green0\\blue0;\\red0\\green0\\blue255;\\red0\\green128\\blue0;}";
        if (pos + color_table.len < rtf.len) {
            @memcpy(rtf[pos..][0..color_table.len], color_table);
            pos += color_table.len;
        }
        
        // Text content
        const text_slice = wp.text_content[0..wp.text_len];
        var i: usize = 0;
        while (i < text_slice.len and pos < rtf.len - 10) : (i += 1) {
            const byte = text_slice[i];
            
            // Apply formatting from attributes
            if (i < wp.attr_count) {
                const attr = wp.text_attrs[i];
                if (attr.bold and pos + 4 < rtf.len) {
                    @memcpy(rtf[pos..][0..3], "\\b ");
                    pos += 3;
                }
                if (attr.italic and pos + 4 < rtf.len) {
                    @memcpy(rtf[pos..][0..4], "\\i ");
                    pos += 4;
                }
            }
            
            // Escape special characters
            switch (byte) {
                '{', '}', '\\' => {
                    if (pos + 2 < rtf.len) {
                        rtf[pos] = '\\';
                        rtf[pos + 1] = byte;
                        pos += 2;
                    }
                },
                '\n' => {
                    if (pos + 2 < rtf.len) {
                        rtf[pos] = '\\';
                        rtf[pos + 1] = 'p';
                        rtf[pos + 2] = 'a';
                        rtf[pos + 3] = 'r';
                        pos += 4;
                    }
                },
                else => {
                    if (pos < rtf.len) {
                        rtf[pos] = byte;
                        pos += 1;
                    }
                },
            }
        }
        
        // Close RTF
        if (pos < rtf.len) {
            rtf[pos] = '}';
            pos += 1;
        }
        
        return rtf[0..pos];
    }

    /// Parse RTF content (simplified)
    pub fn fromRTF(wp: *WordPadWindow, rtf: []const u8) void {
        wp.rtf_len = @min(rtf.len, wp.rtf_content.len);
        @memcpy(wp.rtf_content[0..wp.rtf_len], rtf[0..wp.rtf_len]);
        
        // Simple RTF to plain text conversion
        var in_group: i32 = 0;
        var skip_next: bool = false;
        var text_pos: usize = 0;
        
        wp.text_len = 0;
        wp.attr_count = 0;
        
        var i: usize = 0;
        while (i < rtf.len and text_pos < wp.text_content.len) : (i += 1) {
            const ch = rtf[i];
            
            if (skip_next) {
                skip_next = false;
                continue;
            }
            
            switch (ch) {
                '{' => in_group += 1,
                '}' => {
                    if (in_group > 0) in_group -= 1;
                    if (in_group == 0 and text_pos < wp.text_content.len) {
                        wp.text_content[text_pos] = '\n';
                        text_pos += 1;
                    }
                },
                '\\' => {
                    // Skip RTF control words
                    i += 1;
                    if (i < rtf.len) {
                        const next = rtf[i];
                        if (next == '\\' or next == '{' or next == '}') {
                            if (text_pos < wp.text_content.len) {
                                wp.text_content[text_pos] = next;
                                text_pos += 1;
                            }
                        } else {
                            // Skip until space or non-alphanum
                            while (i < rtf.len and rtf[i] > ' ') : (i += 1) {}
                            i -= 1; // Back up one
                        }
                    }
                },
                '\n', '\r', '\t' => {
                    if (text_pos < wp.text_content.len) {
                        wp.text_content[text_pos] = ' ';
                        text_pos += 1;
                    }
                },
                else => {
                    if (in_group == 0 or (ch >= ' ' and ch < 127)) {
                        if (text_pos < wp.text_content.len) {
                            wp.text_content[text_pos] = ch;
                            text_pos += 1;
                        }
                    }
                },
            }
        }
        
        wp.text_len = text_pos;
        wp.is_rtf = true;
    }

    /// New document
    pub fn newDocument(wp: *WordPadWindow) void {
        wp.text_len = 0;
        wp.rtf_len = 0;
        wp.attr_count = 0;
        wp.modified = false;
        wp.is_rtf = false;
        wp.format_bold = false;
        wp.format_italic = false;
        wp.format_underline = false;
        wp.format_font_size = 11;
        wp.format_font_family = .segoe;
        wp.format_color = rgb(0x20, 0x20, 0x40);
        wp.format_alignment = .left;
        wp.cursor_x = 0;
        wp.cursor_y = 0;
        wp.scroll_offset = 0;
    }

    /// Main render function
    pub fn render(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        if (!wp.visible) return;
        
        if (wp.print_preview) {
            wp.renderPrintPreview(t);
            return;
        }
        
        if (wp.show_font_dialog) {
            wp.renderFontDialog(t);
            return;
        }
        
        wp.renderWindow(t);
        wp.renderMenuBar(t);
        wp.renderToolbar(t);
        wp.renderTextArea(t);
        wp.renderRuler(t);
        wp.renderStatusBar(t);
        
        // Render popup menu if active
        if (wp.active_menu != .none) {
            wp.renderMenuPopup(t);
        }
    }

    /// Render main window
    fn renderWindow(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = wp.x;
        const wy = wp.y;
        const ww = wp.width;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        
        // Title with modified indicator
        var title_buf: [256]u8 = undefined;
        const title_prefix = if (wp.modified) "* " else "";
        const title_suffix = if (wp.is_rtf) " - Rich Text" else " - Document";
        const title_len = std.fmt.bufPrint(&title_buf, "{s}WordPad{s}", .{ title_prefix, title_suffix }) catch "WordPad";
        fb.drawTextTransparent(wx + 8, wy + 10, title_len, rgb(0xFF, 0xFF, 0xFF));

        // Close button
        const close_x = wx + ww - 48;
        if (wp.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));
    }

    /// Render menu bar
    fn renderMenuBar(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const my = wp.y + 32;
        const mh: i32 = 24;
        const menus = [_][]const u8{ "File", "Edit", "View", "Insert", "Format", "Help" };

        fb.fillRect(wp.x, my, wp.width, mh, rgb(0xF0, 0xF4, 0xF8));
        
        var mx = wp.x + 4;
        for (menus, 0..) |menu, idx| {
            const is_active = @as(u8, @intFromEnum(wp.active_menu)) == idx;
            
            if (is_active) {
                fb.fillRect(mx - 2, my + 1, 56, mh - 2, rgb(0xD0, 0xD8, 0xE8));
                fb.drawRect(mx - 2, my + 1, 56, mh - 2, rgb(0x5C, 0x9E, 0xD6));
            }
            
            fb.drawTextTransparent(mx + 4, my + 6, menu, rgb(0x20, 0x20, 0x30));
            mx += 60;
        }
        fb.fillRect(wp.x, my + mh, wp.width, 1, rgb(0xC0, 0xC8, 0xD8));
    }

    /// Render formatting toolbar
    fn renderToolbar(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const ty = wp.y + 57;
        const th: i32 = 40;

        fb.fillRect(wp.x, ty, wp.width, th, rgb(0xF8, 0xFC, 0xFF));
        
        var bx = wp.x + 4;
        
        // File operations
        const file_btns = [_]ToolbarButton{
            .{ .label = "New", .icon = "N", .id = 1 },
            .{ .label = "Open", .icon = "O", .id = 2 },
            .{ .label = "Save", .icon = "S", .id = 3 },
        };
        for (file_btns) |btn| {
            const bw: i32 = 36;
            const bh: i32 = 32;
            const by = ty + 4;
            
            const is_hover = wp.hover_toolbar == btn.id;
            fb.fillRect(bx, by, bw, bh, if (is_hover) rgb(0xD0, 0xD8, 0xE8) else rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(bx, by, bw, bh, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 10, by + 10, btn.icon, rgb(0x40, 0x40, 0x50));
            bx += bw + 2;
        }
        
        // Separator
        fb.fillRect(bx + 2, ty + 6, 1, th - 12, rgb(0xC0, 0xC8, 0xD8));
        bx += 8;
        
        // Clipboard operations
        const clip_btns = [_]ToolbarButton{
            .{ .label = "Cut", .icon = "X", .id = 4 },
            .{ .label = "Copy", .icon = "C", .id = 5 },
            .{ .label = "Paste", .icon = "V", .id = 6 },
        };
        for (clip_btns) |btn| {
            const bw: i32 = 36;
            const bh: i32 = 32;
            const by = ty + 4;
            
            const is_hover = wp.hover_toolbar == btn.id;
            fb.fillRect(bx, by, bw, bh, if (is_hover) rgb(0xD0, 0xD8, 0xE8) else rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(bx, by, bw, bh, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 10, by + 10, btn.icon, rgb(0x40, 0x40, 0x50));
            bx += bw + 2;
        }
        
        // Separator
        fb.fillRect(bx + 2, ty + 6, 1, th - 12, rgb(0xC0, 0xC8, 0xD8));
        bx += 8;
        
        // Formatting buttons
        const format_btns = [_]ToolbarButton{
            .{ .label = "B", .icon = "B", .bold = true, .id = 10 },
            .{ .label = "I", .icon = "I", .italic = true, .id = 11 },
            .{ .label = "U", .icon = "U", .underline = true, .id = 12 },
        };
        for (format_btns) |btn| {
            const bw: i32 = 28;
            const bh: i32 = 32;
            const by = ty + 4;
            
            const is_hover = wp.hover_toolbar == btn.id;
            const is_active = switch (btn.id) {
                10 => wp.format_bold,
                11 => wp.format_italic,
                12 => wp.format_underline,
                else => false,
            };
            
            fb.fillRect(bx, by, bw, bh, if (is_active) rgb(0xC8, 0xD0, 0xE0) else if (is_hover) rgb(0xD0, 0xD8, 0xE8) else rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(bx, by, bw, bh, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            
            const text_color = if (btn.bold) rgb(0x00, 0x00, 0x00) else if (btn.italic) rgb(0x20, 0x20, 0x80) else rgb(0x40, 0x40, 0x50);
            fb.drawTextTransparent(bx + 8, by + 10, btn.icon, text_color);
            bx += bw + 2;
        }
        
        // Separator
        fb.fillRect(bx + 2, ty + 6, 1, th - 12, rgb(0xC0, 0xC8, 0xD8));
        bx += 8;
        
        // Font size selector
        const size_btns = [_]ToolbarButton{
            .{ .label = "8", .id = 20 },
            .{ .label = "10", .id = 21 },
            .{ .label = "12", .id = 22 },
            .{ .label = "14", .id = 23 },
            .{ .label = "18", .id = 24 },
            .{ .label = "24", .id = 25 },
        };
        for (size_btns) |btn| {
            const bw: i32 = 32;
            const bh: i32 = 28;
            const by = ty + 6;
            
            const is_hover = wp.hover_toolbar == btn.id;
            const is_active = wp.format_font_size == std.fmt.parseInt(i32, btn.label, 10) catch 11;
            
            fb.fillRect(bx, by, bw, bh, if (is_active) rgb(0xC8, 0xD0, 0xE0) else if (is_hover) rgb(0xD0, 0xD8, 0xE8) else rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(bx, by, bw, bh, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 6, by + 8, btn.label, rgb(0x40, 0x40, 0x50));
            bx += bw + 2;
        }
        
        // Separator
        fb.fillRect(bx + 2, ty + 6, 1, th - 12, rgb(0xC0, 0xC8, 0xD8));
        bx += 8;
        
        // Color buttons
        const color_btns = [_]ToolbarButton{
            .{ .label = "A", .id = 30, .color = rgb(0x00, 0x00, 0x00) },
            .{ .label = "A", .id = 31, .color = rgb(0xFF, 0x00, 0x00) },
            .{ .label = "A", .id = 32, .color = rgb(0x00, 0x00, 0xFF) },
            .{ .label = "A", .id = 33, .color = rgb(0x00, 0x80, 0x00) },
        };
        for (color_btns) |btn| {
            const bw: i32 = 24;
            const bh: i32 = 28;
            const by = ty + 6;
            
            const is_hover = wp.hover_toolbar == btn.id;
            const is_active = wp.format_color == btn.color;
            
            fb.fillRect(bx, by, bw, bh, if (is_active) rgb(0xC8, 0xD0, 0xE0) else if (is_hover) rgb(0xD0, 0xD8, 0xE8) else rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(bx, by, bw, bh, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 6, by + 8, "A", btn.color);
            bx += bw + 2;
        }
        
        fb.fillRect(wp.x, ty + th, wp.width, 1, rgb(0xC0, 0xC8, 0xD8));
    }

    /// Render text area
    fn renderTextArea(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const tx = wp.x + 8;
        const ty = wp.y + 98;
        const tw = wp.width - 16;
        const th = wp.height - 145;

        fb.draw3DRect(tx, ty, tw, th, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(tx + 2, ty + 2, tw - 4, th - 4, rgb(0xFF, 0xFF, 0xFF));

        // Draw text with formatting
        const text_y = ty + 20 - wp.scroll_offset;
        var line_y = text_y;
        var char_x = tx + 20;

        var i: usize = 0;
        while (i < wp.text_len) : (i += 1) {
            const byte = wp.text_content[i];
            
            // Get character attributes
            var attr_color = wp.format_color;
            var attr_bold = wp.format_bold;
            var attr_italic = wp.format_italic;
            var attr_underline = wp.format_underline;
            
            if (i < wp.attr_count) {
                const a = wp.text_attrs[i];
                attr_color = a.color;
                attr_bold = a.bold;
                attr_italic = a.italic;
                attr_underline = a.underline;
            }
            
            // Line wrapping
            if (byte == '\n' or char_x > tx + tw - 40) {
                line_y += wp.format_font_size + 4;
                char_x = switch (wp.format_alignment) {
                    .left => tx + 20,
                    .center => tx + tw / 2,
                    .right => tx + tw - 20,
                    .justify => tx + 20,
                };
            }
            
            // Draw character
            const char_str = [_]u8{byte};
            fb.drawTextTransparent(char_x, line_y, &char_str, attr_color);
            char_x += if (attr_bold) 10 else 8;
            
            // Draw underline if needed
            if (attr_underline) {
                fb.drawHLine(char_x - 6, line_y + wp.format_font_size - 2, 6, attr_color);
            }
        }

        // Draw cursor
        const cursor_blink: bool = true;
        _ = cursor_blink;
        const cursor_color = wp.format_color;
        const cursor_w: i32 = if (wp.format_bold) 2 else 1;
        fb.fillRect(tx + 20 + wp.cursor_x * 8, ty + 20 + wp.cursor_y * (wp.format_font_size + 4), cursor_w, wp.format_font_size, cursor_color);
    }

    /// Render ruler (for paragraph formatting)
    fn renderRuler(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const rx = wp.x + 8;
        const ry = wp.y + 95;
        const rw = wp.width - 16;
        const rh: i32 = 18;

        fb.fillRect(rx, ry, rw, rh, rgb(0xF0, 0xF4, 0xF8));
        
        // Ruler marks
        var x: i32 = rx;
        while (x < rx + rw) : (x += 50) {
            fb.drawVLine(x, ry + rh - 6, 6, rgb(0x80, 0x80, 0x80));
        }
        
        // Paragraph alignment indicator
        const align_x = switch (wp.format_alignment) {
            .left => rx + 20,
            .center => rx + rw / 2,
            .right => rx + rw - 20,
            .justify => rx + rw / 2,
        };
        
        fb.fillRect(align_x - 1, ry + 2, 3, rh - 4, rgb(0x00, 0x00, 0x80));
    }

    /// Render status bar
    fn renderStatusBar(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const sy = wp.y + wp.height - 26;
        const sh: i32 = 26;

        fb.fillRect(wp.x, sy, wp.width, sh, rgb(0xF0, 0xF4, 0xF8));
        fb.fillRect(wp.x, sy, wp.width, 1, rgb(0xC0, 0xC8, 0xD8));

        // Page/line info
        var buf: [64]u8 = undefined;
        const page_str = std.fmt.bufPrint(&buf, "Page 1, Line {d}, Col {d}", .{ wp.cursor_y + 1, wp.cursor_x + 1 }) catch "";
        fb.drawTextTransparent(wp.x + 8, sy + 7, page_str, rgb(0x40, 0x40, 0x50));

        // Modified indicator
        const modified_str = if (wp.modified) "Modified" else "Ready";
        fb.drawTextTransparent(wp.x + wp.width - 70, sy + 7, modified_str, rgb(0x40, 0x40, 0x50));

        // Word count
        var size_buf: [16]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d} words", .{wp.text_len / 5}) catch "";
        fb.drawTextTransparent(wp.x + wp.width / 2 - 30, sy + 7, size_str, rgb(0x60, 0x60, 0x70));
    }

    /// Render popup menu
    fn renderMenuPopup(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const mx = wp.x + 4 + @as(i32, @intFromEnum(wp.active_menu)) * 60;
        const my = wp.y + 56;
        
        const menu_items = switch (wp.active_menu) {
            .file => &.{ "New", "Open...", "Save", "Save As...", "Print...", "Exit" },
            .edit => &.{ "Undo", "Cut", "Copy", "Paste", "Delete", "Select All" },
            .view => &.{ "Status Bar", "Format Bar", "Ruler" },
            .insert => &.{ "Date and Time" },
            .format => &.{ "Font...", "Paragraph", "Bullets" },
            .help => &.{ "Help Topics", "About WordPad" },
            else => &.{},
        };
        
        const menu_h: i32 = @intCast(menu_items.len * 20 + 4);
        const menu_w: i32 = 120;
        
        fb.fillRect(mx, my, menu_w, menu_h, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(mx, my, menu_w, menu_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF0));
        
        var iy = my + 2;
        for (menu_items, 0..) |item, idx| {
            if (wp.hover_menu_item == @as(i32, @intCast(idx))) {
                fb.fillRect(mx + 2, iy, menu_w - 4, 18, rgb(0xD0, 0xD8, 0xE8));
            }
            fb.drawTextTransparent(mx + 8, iy + 4, item, rgb(0x20, 0x20, 0x30));
            iy += 20;
        }
    }

    /// Render font dialog
    fn renderFontDialog(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const dw = 350;
        const dh = 280;
        const dx = wp.x + (wp.width - dw) / 2;
        const dy = wp.y + (wp.height - dh) / 2;
        
        // Dialog background
        fb.fillRect(dx, dy, dw, dh, rgb(0xF0, 0xF4, 0xF8));
        fb.draw3DRect(dx, dy, dw, dh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
        
        // Title
        fb.drawTextTransparent(dx + 10, dy + 10, "Font", rgb(0x20, 0x20, 0x40));
        
        // Font family list
        fb.drawTextTransparent(dx + 10, dy + 40, "Font:", rgb(0x40, 0x40, 0x50));
        const families = [_][]const u8{ "Arial", "Times New Roman", "Courier New", "Segoe UI", "Calibri" };
        var fy = dy + 60;
        for (families, 0..) |fam, idx| {
            const is_selected = wp.font_dialog_hover == @as(i32, @intCast(idx));
            fb.fillRect(dx + 10, fy, dw - 20, 20, if (is_selected) rgb(0xD0, 0xD8, 0xE8) else rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(dx + 14, fy + 4, fam, rgb(0x20, 0x20, 0x30));
            fy += 22;
        }
        
        // Size list
        fb.drawTextTransparent(dx + 180, dy + 40, "Size:", rgb(0x40, 0x40, 0x50));
        const sizes = [_][]const u8{ "8", "10", "11", "12", "14", "16", "18", "20", "24", "36", "48", "72" };
        var sy = dy + 60;
        for (sizes, 0..) |size, idx| {
            const is_selected = wp.font_dialog_hover == @as(i32, @intCast(idx + 100));
            fb.fillRect(dx + 180, sy, 80, 18, if (is_selected) rgb(0xD0, 0xD8, 0xE8) else rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(dx + 184, sy + 3, size, rgb(0x20, 0x20, 0x30));
            sy += 20;
        }
        
        // Style options
        fb.drawTextTransparent(dx + 10, dy + 200, "Style:", rgb(0x40, 0x40, 0x50));
        
        const style_x: i32 = dx + 60;
        fb.fillRect(style_x, dy + 198, 50, 18, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(style_x, dy + 198, 50, 18, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(style_x + 10, dy + 202, "Bold", if (wp.format_bold) rgb(0x00, 0x00, 0x80) else rgb(0x40, 0x40, 0x50));
        
        fb.fillRect(style_x + 60, dy + 198, 55, 18, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(style_x + 60, dy + 198, 55, 18, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(style_x + 68, dy + 202, "Italic", if (wp.format_italic) rgb(0x00, 0x00, 0x80) else rgb(0x40, 0x40, 0x50));
        
        // Buttons
        const ok_x = dx + dw - 180;
        const ok_y = dy + dh - 36;
        fb.fillRect(ok_x, ok_y, 70, 26, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(ok_x, ok_y, 70, 26, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(ok_x + 22, ok_y + 8, "OK", rgb(0x20, 0x20, 0x30));
        
        fb.fillRect(ok_x + 80, ok_y, 70, 26, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(ok_x + 80, ok_y, 70, 26, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(ok_x + 88, ok_y + 8, "Cancel", rgb(0x20, 0x20, 0x30));
    }

    /// Render print preview
    fn renderPrintPreview(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const px = wp.x + 50;
        const py = wp.y + 60;
        const pw = wp.width - 100;
        const ph = wp.height - 120;
        
        // Page preview area
        fb.fillRect(px, py, pw, ph, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(px, py, pw, ph, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF0));
        
        // Simulated page content
        const page_y = py + 40;
        const margin_x = px + 60;
        const page_text_w = pw - 120;
        
        var line_y = page_y;
        var char_x = margin_x;
        var printed: usize = 0;
        const chars_per_page: usize = 1500;
        
        while (printed < wp.text_len and line_y < py + ph - 60 and printed < chars_per_page * @as(usize, @intCast(wp.preview_page))) : ({
            printed += 1;
        }) {
            if (printed < (wp.preview_page - 1) * chars_per_page) continue;
            
            const byte = wp.text_content[printed % wp.text_len];
            
            if (byte == '\n' or char_x > margin_x + page_text_w) {
                line_y += 18;
                char_x = margin_x;
            }
            
            if (byte >= ' ' and byte < 127) {
                const ch = [_]u8{byte};
                fb.drawTextTransparent(char_x, line_y, &ch, rgb(0x20, 0x20, 0x40));
                char_x += 8;
            }
        }
        
        // Page number
        var page_buf: [32]u8 = undefined;
        const page_str = std.fmt.bufPrint(&page_buf, "Page {d} of {d}", .{ wp.preview_page, wp.total_pages }) catch "";
        fb.drawTextTransparent(wp.x + wp.width / 2 - 40, py + ph + 10, page_str, rgb(0x40, 0x40, 0x50));
        
        // Navigation buttons
        const nav_y = wp.y + wp.height - 30;
        const prev_x = wp.x + wp.width / 2 - 100;
        const next_x = wp.x + wp.width / 2 + 20;
        
        fb.fillRect(prev_x, nav_y, 80, 22, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(prev_x, nav_y, 80, 22, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(prev_x + 20, nav_y + 6, "Previous", rgb(0x20, 0x20, 0x30));
        
        fb.fillRect(next_x, nav_y, 80, 22, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(next_x, nav_y, 80, 22, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(next_x + 24, nav_y + 6, "Next", rgb(0x20, 0x20, 0x30));
        
        // Close preview
        fb.fillRect(wp.x + wp.width - 90, wp.y + 32, 80, 22, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(wp.x + wp.width - 90, wp.y + 32, 80, 22, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(wp.x + wp.width - 72, wp.y + 38, "Close", rgb(0x20, 0x20, 0x30));
    }

    const ToolbarButton = struct {
        separator: bool = false,
        label: []const u8 = "",
        icon: []const u8 = "",
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
        id: i32 = -1,
        color: u32 = 0,
    };
};
