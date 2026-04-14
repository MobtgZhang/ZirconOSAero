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
// Module: src/desktop/applications/accessories/sticky_notes.zig
// Purpose: Windows 7 style Sticky Notes application
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

/// Maximum number of sticky notes
const MAX_NOTES = 16;
/// Maximum characters per note
const MAX_NOTE_TEXT = 1024;

/// Note color options
pub const NoteColor = enum(u8) {
    yellow = 0,
    pink = 1,
    blue = 2,
    green = 3,
    purple = 4,
};

/// Individual sticky note
pub const StickyNote = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    pinned: bool,
    color: NoteColor,
    text: [MAX_NOTE_TEXT]u8,
    text_len: usize,
    hover_close: bool,
    hover_color: bool,
    hover_pin: bool,
    is_editing: bool,
    scroll_offset: i32,

    /// Get the background color for this note
    pub fn getBackgroundColor(note: *const StickyNote) u32 {
        return switch (note.color) {
            .yellow => rgb(0xFF, 0xFF, 0xE0),
            .pink => rgb(0xFF, 0xE0, 0xE8),
            .blue => rgb(0xE0, 0xF0, 0xFF),
            .green => rgb(0xE0, 0xFF, 0xE0),
            .purple => rgb(0xF0, 0xE0, 0xFF),
        };
    }

    /// Get the border color for this note
    pub fn getBorderColor(note: *const StickyNote) u32 {
        return switch (note.color) {
            .yellow => rgb(0xE0, 0xE0, 0x80),
            .pink => rgb(0xE0, 0xA0, 0xB8),
            .blue => rgb(0xA0, 0xC0, 0xE0),
            .green => rgb(0xA0, 0xE0, 0xA0),
            .purple => rgb(0xC0, 0xA0, 0xE0),
        };
    }

    /// Get the text color for this note
    pub fn getTextColor(note: *const StickyNote) u32 {
        _ = note;
        return rgb(0x30, 0x30, 0x30);
    }
};

/// Sticky Notes window manager
pub const StickyNotesWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,

    // Note management
    notes: [MAX_NOTES]?StickyNote,
    note_count: usize,
    active_note: usize,

    // UI state
    show_new_menu: bool,
    hover_new: bool,

    // Main window content
    main_text: [512]u8,
    main_text_len: usize,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) StickyNotesWindow {
        var notes: [MAX_NOTES]?StickyNote = undefined;
        for (&notes) |*n| {
            n.* = null;
        }

        return .{
            .x = x_pos,
            .y = y_pos,
            .width = 300,
            .height = 350,
            .visible = true,
            .caption_hover = .none,
            .notes = notes,
            .note_count = 0,
            .active_note = 0,
            .show_new_menu = false,
            .hover_new = false,
            .main_text = undefined,
            .main_text_len = 0,
        };
    }

    /// Create a new sticky note
    pub fn createNote(wn: *StickyNotesWindow, x: i32, y: i32, color: NoteColor) bool {
        if (wn.note_count >= MAX_NOTES) return false;

        var note = StickyNote{
            .x = x,
            .y = y,
            .width = 200,
            .height = 200,
            .visible = true,
            .pinned = false,
            .color = color,
            .text = undefined,
            .text_len = 0,
            .hover_close = false,
            .hover_color = false,
            .hover_pin = false,
            .is_editing = false,
            .scroll_offset = 0,
        };

        // Initialize with default greeting
        const greeting = "Tap and type your note...";
        @memcpy(note.text[0..greeting.len], greeting);
        note.text_len = greeting.len;

        wn.notes[wn.note_count] = note;
        wn.active_note = wn.note_count;
        wn.note_count += 1;

        return true;
    }

    /// Delete a note
    pub fn deleteNote(wn: *StickyNotesWindow, note_index: usize) void {
        if (note_index >= wn.note_count) return;

        wn.notes[note_index] = null;

        // Shift notes down
        var i = note_index;
        while (i < MAX_NOTES - 1) : (i += 1) {
            wn.notes[i] = wn.notes[i + 1];
        }
        wn.notes[MAX_NOTES - 1] = null;
        wn.note_count -= 1;

        if (wn.active_note >= wn.note_count and wn.note_count > 0) {
            wn.active_note = wn.note_count - 1;
        }
    }

    /// Add text to the active note
    pub fn addText(wn: *StickyNotesWindow, text: []const u8) void {
        if (wn.note_count == 0) return;

        const note = &wn.notes[wn.active_note];
        if (note == null) return;

        const n = note.?;
        if (n.text_len + text.len < MAX_NOTE_TEXT) {
            @memcpy(n.text[n.text_len..][0..text.len], text);
            n.text_len += text.len;
        }
    }

    /// Handle backspace on active note
    pub fn backspace(wn: *StickyNotesWindow) void {
        if (wn.note_count == 0) return;

        var n = &wn.notes[wn.active_note];
        if (n == null) return;

        if (n.text_len > 0) {
            n.text_len -= 1;
        }
    }

    /// Change color of active note
    pub fn setNoteColor(wn: *StickyNotesWindow, color: NoteColor) void {
        if (wn.note_count == 0) return;

        var n = &wn.notes[wn.active_note];
        if (n != null) {
            n.color = color;
        }
    }

    /// Toggle pin state of active note
    pub fn togglePin(wn: *StickyNotesWindow) void {
        if (wn.note_count == 0) return;

        var n = &wn.notes[wn.active_note];
        if (n != null) {
            n.pinned = !n.pinned;
        }
    }

    /// Main render function
    pub fn render(wn: *StickyNotesWindow, t: *const theme_mod.ThemeColors) void {
        if (!wn.visible) return;

        // Render main manager window (when no notes exist)
        if (wn.note_count == 0) {
            wn.renderWelcome(t);
            return;
        }

        // Render all visible notes
        var i: usize = 0;
        while (i < wn.note_count) : (i += 1) {
            if (wn.notes[i]) |*note| {
                wn.renderNote(note);
            }
        }

        // Render new note button/menu if showing
        if (wn.show_new_menu) {
            wn.renderNewNoteMenu();
        }
    }

    /// Render welcome screen when no notes exist
    fn renderWelcome(wn: *StickyNotesWindow, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = wn.x;
        const wy = wn.y;
        const ww = wn.width;
        const wh = wn.height;

        // Window background
        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 6, "Sticky Notes", rgb(0xFF, 0xFF, 0xFF));

        // Close button
        const close_x = wx + ww - 48;
        if (wn.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        // Main content area
        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 34, rgb(0xF8, 0xFC, 0xFF));

        // Welcome message
        const cx = wx + ww / 2;
        const cy = wy + wh / 2 - 30;

        fb.drawTextTransparent(cx - 70, cy, "No sticky notes yet", rgb(0x40, 0x40, 0x50));
        fb.drawTextTransparent(cx - 85, cy + 25, "Click below to create one", rgb(0x60, 0x60, 0x70));

        // New note button
        const btn_x = cx - 50;
        const btn_y = cy + 60;
        const btn_w: i32 = 100;
        const btn_h: i32 = 32;

        if (wn.hover_new) {
            fb.fillRect(btn_x, btn_y, btn_w, btn_h, rgb(0xD0, 0xD8, 0xE8));
            fb.draw3DRect(btn_x, btn_y, btn_w, btn_h, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
        } else {
            fb.fillRect(btn_x, btn_y, btn_w, btn_h, rgb(0xFF, 0xFF, 0xE0));
            fb.draw3DRect(btn_x, btn_y, btn_w, btn_h, rgb(0xE0, 0xE0, 0x80), rgb(0xC0, 0xC0, 0x60));
        }
        fb.drawTextTransparent(btn_x + 20, btn_y + 10, "+ New Note", rgb(0x30, 0x30, 0x30));

        // Border
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    }

    /// Render a single sticky note
    fn renderNote(_: *StickyNotesWindow, note: *StickyNote) void {
        const nx = note.x;
        const ny = note.y;
        const nw = note.width;
        const nh = note.height;

        // Note shadow
        fb.fillRect(nx + 4, ny + 4, nw, nh, rgb(0x40, 0x40, 0x50));

        // Note background
        const bg_color = note.getBackgroundColor();
        fb.fillRect(nx, ny, nw, nh, bg_color);

        // Note border
        const border_color = note.getBorderColor();
        fb.draw3DRect(nx, ny, nw, nh, border_color, border_color);

        // Title bar area (visual strip)
        fb.fillRect(nx + 1, ny + 1, nw - 2, 24, bg_color);
        fb.fillRect(nx, ny, nw, 1, border_color);
        fb.fillRect(nx, ny + 25, nw, 1, border_color);

        // Color indicator strip at top
        fb.fillRect(nx, ny, nw, 3, switch (note.color) {
            .yellow => rgb(0xFF, 0xD0, 0x00),
            .pink => rgb(0xFF, 0x80, 0xA0),
            .blue => rgb(0x40, 0xA0, 0xE0),
            .green => rgb(0x60, 0xD0, 0x60),
            .purple => rgb(0xA0, 0x60, 0xD0),
        });

        // Pin icon if pinned
        if (note.pinned) {
            fb.drawTextTransparent(nx + 4, ny + 8, "*", rgb(0x60, 0x60, 0x60));
        }

        // Close button
        const close_x = nx + nw - 20;
        if (note.hover_close) {
            fb.fillRect(close_x, ny + 4, 16, 16, rgb(0xE8, 0x11, 0x23));
            fb.drawTextTransparent(close_x + 3, ny + 8, "x", rgb(0xFF, 0xFF, 0xFF));
        } else {
            fb.fillRect(close_x, ny + 4, 16, 16, rgb(0xCC, 0xCC, 0xCC));
            fb.drawTextTransparent(close_x + 3, ny + 8, "x", rgb(0x40, 0x40, 0x40));
        }

        // Color button
        const color_x = nx + nw - 38;
        if (note.hover_color) {
            fb.fillRect(color_x, ny + 4, 16, 16, rgb(0xCC, 0xCC, 0xCC));
            fb.drawTextTransparent(color_x + 2, ny + 8, "*", rgb(0x60, 0x60, 0x60));
        }

        // Note text content
        const text_x = nx + 8;
        const text_y = ny + 32;
        const text_w = nw - 16;

        var line_y = text_y;
        var char_x = text_x;
        var printed: usize = 0;

        while (printed < note.text_len and line_y < ny + nh - 8) {
            const ch = note.text[printed];
            printed += 1;

            if (ch == '\n' or char_x >= text_x + text_w - 8) {
                line_y += 16;
                char_x = text_x;
                continue;
            }

            if (ch >= ' ' and ch < 127) {
                const byte_arr = [_]u8{ch};
                fb.drawTextTransparent(char_x, line_y, &byte_arr, note.getTextColor());
                char_x += 8;
            }
        }

        // Editing cursor (blinking)
        if (note.is_editing) {
            const cursor_x = char_x;
            const cursor_y = line_y;
            fb.fillRect(cursor_x, cursor_y, 1, 14, rgb(0x30, 0x30, 0x30));
        }
    }

    /// Render the new note creation menu
    fn renderNewNoteMenu(wn: *StickyNotesWindow) void {
        const mx = wn.x + 50;
        const my = wn.y + 80;
        const mw: i32 = 200;
        const mh: i32 = 150;

        // Menu background
        fb.fillRect(mx, my, mw, mh, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(mx, my, mw, mh, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF0));

        // Title
        fb.drawTextTransparent(mx + 10, my + 10, "Choose a color:", rgb(0x40, 0x40, 0x50));

        // Color options
        const colors = [_]struct { color: NoteColor, name: []const u8, rgb_val: u32 }{
            .{ .color = .yellow, .name = "Yellow", .rgb_val = rgb(0xFF, 0xFF, 0xE0) },
            .{ .color = .pink, .name = "Pink", .rgb_val = rgb(0xFF, 0xE0, 0xE8) },
            .{ .color = .blue, .name = "Blue", .rgb_val = rgb(0xE0, 0xF0, 0xFF) },
            .{ .color = .green, .name = "Green", .rgb_val = rgb(0xE0, 0xFF, 0xE0) },
            .{ .color = .purple, .name = "Purple", .rgb_val = rgb(0xF0, 0xE0, 0xFF) },
        };

        var cy = my + 35;
        for (colors, 0..) |entry, idx| {
            const is_hover = wn.hover_new and wn.active_note == idx;

            fb.fillRect(mx + 10, cy, mw - 20, 20, if (is_hover) rgb(0xE8, 0xEC, 0xF4) else rgb(0xF8, 0xF8, 0xF8));
            fb.draw3DRect(mx + 10, cy, 16, 16, entry.rgb_val, entry.rgb_val);
            fb.drawTextTransparent(mx + 34, cy + 4, entry.name, rgb(0x30, 0x30, 0x30));

            cy += 22;
        }
    }

    /// Handle click at position
    pub fn handleClick(wn: *StickyNotesWindow, px: i32, py: i32) bool {
        // If no notes, check welcome button
        if (wn.note_count == 0) {
            const btn_x = wn.x + wn.width / 2 - 50;
            const btn_y = wn.y + wn.height / 2 + 30;

            if (px >= btn_x and px < btn_x + 100 and py >= btn_y and py < btn_y + 32) {
                // Create default yellow note
                const note_x = wn.x + 50;
                const note_y = wn.y + 50;
                _ = wn.createNote(note_x, note_y, .yellow);
                return true;
            }
            return false;
        }

        // Check notes in reverse order (topmost first)
        var i: isize = @as(isize, @intCast(wn.note_count)) - 1;
        while (i >= 0) : (i -= 1) {
            const idx = @as(usize, @intCast(i));
            if (wn.notes[idx]) |*note| {
                // Check close button
                const close_x = note.x + note.width - 20;
                if (px >= close_x and px < close_x + 16 and py >= note.y + 4 and py < note.y + 20) {
                    wn.deleteNote(idx);
                    return true;
                }

                // Check if within note bounds
                if (px >= note.x and px < note.x + note.width and
                    py >= note.y and py < note.y + note.height)
                {
                    wn.active_note = idx;

                    // Check title bar area for dragging
                    if (py < note.y + 26) {
                        return true; // Title bar interaction
                    }

                    // Start editing
                    note.is_editing = true;
                    return true;
                }
            }
        }

        // Deactivate editing on all notes
        for (&wn.notes) |*note_opt| {
            if (note_opt.*) |*note| {
                note.is_editing = false;
            }
        }

        return false;
    }

    /// Handle text input (called when a note is being edited)
    pub fn handleTextInput(wn: *StickyNotesWindow, ch: u8) bool {
        if (wn.note_count == 0) return false;

        var note = &wn.notes[wn.active_note];
        if (note == null or !note.is_editing) return false;

        if (ch >= ' ' and ch < 127) {
            if (note.text_len < MAX_NOTE_TEXT - 1) {
                note.text[note.text_len] = ch;
                note.text_len += 1;
                return true;
            }
        }

        return false;
    }

    /// Handle backspace on active note
    pub fn handleBackspace(wn: *StickyNotesWindow) bool {
        if (wn.note_count == 0) return false;

        var note = &wn.notes[wn.active_note];
        if (note == null or !note.is_editing) return false;

        if (note.text_len > 0) {
            note.text_len -= 1;
            return true;
        }

        return false;
    }

    /// Move active note by delta
    pub fn moveActiveNote(wn: *StickyNotesWindow, dx: i32, dy: i32) void {
        if (wn.note_count == 0) return;

        var note = &wn.notes[wn.active_note];
        if (note == null) return;

        note.x += dx;
        note.y += dy;
    }

    /// Resize active note
    pub fn resizeActiveNote(wn: *StickyNotesWindow, new_width: i32, new_height: i32) void {
        if (wn.note_count == 0) return;

        var note = &wn.notes[wn.active_note];
        if (note == null) return;

        note.width = @max(100, new_width);
        note.height = @max(80, new_height);
    }

    /// Get the count of notes
    pub fn getNoteCount(wn: *const StickyNotesWindow) usize {
        return wn.note_count;
    }

    /// Export all notes as text (for clipboard)
    pub fn exportAllNotes(wn: *const StickyNotesWindow, buf: []u8) usize {
        var pos: usize = 0;
        var i: usize = 0;

        while (i < wn.note_count) : (i += 1) {
            if (wn.notes[i]) |note| {
                // Add note separator
                if (pos < buf.len - 1) {
                    buf[pos] = '-';
                    pos += 1;
                }
                if (pos < buf.len - 1) {
                    buf[pos] = '-';
                    pos += 1;
                }
                if (pos < buf.len - 1) {
                    buf[pos] = '-';
                    pos += 1;
                }
                if (pos < buf.len - 1) {
                    buf[pos] = '\n';
                    pos += 1;
                }

                // Add note text
                var j: usize = 0;
                while (j < note.text_len and pos < buf.len - 1) : (j += 1) {
                    buf[pos] = note.text[j];
                    pos += 1;
                }

                if (pos < buf.len - 1) {
                    buf[pos] = '\n';
                    pos += 1;
                }
            }
        }

        return pos;
    }
};
