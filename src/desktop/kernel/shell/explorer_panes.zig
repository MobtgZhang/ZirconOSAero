//! Explorer Preview Pane and Details Pane - Windows 7 Style
//!
//! Implements the Windows 7-style preview pane and details pane for file information
//! and content preview. Clean-room implementation based on publicly documented
//! Windows 7 Explorer behavior.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const explorer_vol_snap = @import("../../../fs/explorer_volume_snapshot.zig");

const rgb = theme.rgb;

// ── Pane Visibility State ───────────────────────────────────────────────────

var preview_pane_visible: bool = false;
var details_pane_visible: bool = false;

pub fn isPreviewPaneVisible() bool {
    return preview_pane_visible;
}

pub fn togglePreviewPane() void {
    preview_pane_visible = !preview_pane_visible;
}

pub fn setPreviewPaneVisible(visible: bool) void {
    preview_pane_visible = visible;
}

pub fn isDetailsPaneVisible() bool {
    return details_pane_visible;
}

pub fn toggleDetailsPane() void {
    details_pane_visible = !details_pane_visible;
}

pub fn setDetailsPaneVisible(visible: bool) void {
    details_pane_visible = visible;
}

// ── Preview Pane Dimensions ──────────────────────────────────────────────────

const PREVIEW_PANE_W: i32 = 300;
const DETAILS_PANE_H: i32 = 180;

// ── Preview Pane Rendering ────────────────────────────────────────────────────

pub fn renderPreviewPane(
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    entry: explorer_vol_snap.ExplorerListEntry,
) void {
    // Background
    fb.fillRect(x, y, w, h, rgb(0xF5, 0xF5, 0xF5));
    
    // Border
    fb.drawRect(x, y, w, h, rgb(0xCC, 0xCC, 0xCC));
    
    // Preview title
    const title = "Preview";
    fb.drawTextTransparent(x + 8, y + 8, title, rgb(0x18, 0x18, 0x18));
    fb.drawHLine(x, y + 28, w, rgb(0xDD, 0xDD, 0xDD));
    
    // Content area
    const content_x = x + 8;
    const content_y = y + 36;
    const content_w = w - 16;
    const content_h = h - 44;
    
    // Try to render preview based on file type
    const name = entry.name[0..entry.name_len];
    const ext = getExtension(name);
    
    if (entry.is_directory) {
        renderFolderPreview(content_x, content_y, content_w, content_h);
    } else if (isImageExtension(ext)) {
        renderImagePreview(content_x, content_y, content_w, content_h, entry);
    } else if (isTextExtension(ext)) {
        renderTextPreview(content_x, content_y, content_w, content_h, entry);
    } else {
        renderNoPreviewAvailable(content_x, content_y, content_w, content_h);
    }
}

fn renderFolderPreview(x: i32, y: i32, w: i32, h: i32) void {
    fb.drawTextTransparent(x + w / 2 - 30, y + h / 2 - 20, "[ Folder ]", rgb(0x60, 0x60, 0x60));
    fb.drawTextTransparent(x + w / 2 - 40, y + h / 2, "No preview available", rgb(0xA0, 0xA0, 0xA0));
}

fn renderImagePreview(
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    entry: explorer_vol_snap.ExplorerListEntry,
) void {
    _ = entry;
    // Placeholder for image preview
    // In a full implementation, this would load and render the image
    fb.drawRect(x, y, w, h, rgb(0xDD, 0xDD, 0xDD));
    fb.drawTextTransparent(x + w / 2 - 40, y + h / 2 - 10, "[ Image Preview ]", rgb(0x60, 0x60, 0x60));
    fb.drawTextTransparent(x + w / 2 - 50, y + h / 2 + 10, "Image preview not available", rgb(0xA0, 0xA0, 0xA0));
}

fn renderTextPreview(
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    entry: explorer_vol_snap.ExplorerListEntry,
) void {
    _ = entry;
    // Placeholder for text preview
    fb.fillRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));
    fb.drawTextTransparent(x + 4, y + 4, "[ Text Preview ]", rgb(0x60, 0x60, 0x60));
    fb.drawTextTransparent(x + 4, y + 24, "Text content would be", rgb(0x50, 0x50, 0x50));
    fb.drawTextTransparent(x + 4, y + 38, "displayed here.", rgb(0x50, 0x50, 0x50));
}

fn renderNoPreviewAvailable(x: i32, y: i32, w: i32, h: i32) void {
    fb.drawRect(x, y, w, h, rgb(0xDD, 0xDD, 0xDD));
    fb.drawTextTransparent(x + w / 2 - 60, y + h / 2 - 10, "No preview available", rgb(0x60, 0x60, 0x60));
}

// ── Details Pane Rendering ────────────────────────────────────────────────────

pub fn renderDetailsPane(
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    entry: explorer_vol_snap.ExplorerListEntry,
) void {
    // Background
    fb.fillRect(x, y, w, h, rgb(0xF5, 0xF5, 0xF5));
    
    // Border
    fb.drawRect(x, y, w, h, rgb(0xCC, 0xCC, 0xCC));
    
    // Details title
    const title = "Details";
    fb.drawTextTransparent(x + 8, y + 8, title, rgb(0x18, 0x18, 0x18));
    fb.drawHLine(x, y + 28, w, rgb(0xDD, 0xDD, 0xDD));
    
    // Content area
    const label_x = x + 8;
    const value_x = x + 100;
    var row_y = y + 36;
    const row_h: i32 = 18;
    
    // File name
    fb.drawTextTransparent(label_x, row_y, "Name:", rgb(0x60, 0x60, 0x60));
    fb.drawTextTransparent(value_x, row_y, entry.name[0..entry.name_len], rgb(0x18, 0x18, 0x18));
    row_y += row_h;
    
    // Size
    fb.drawTextTransparent(label_x, row_y, "Size:", rgb(0x60, 0x60, 0x60));
    if (entry.is_directory) {
        fb.drawTextTransparent(value_x, row_y, "--", rgb(0x18, 0x18, 0x18));
    } else {
        fb.drawTextTransparent(value_x, row_y, entry.size[0..entry.size_len], rgb(0x18, 0x18, 0x18));
    }
    row_y += row_h;
    
    // Item type
    fb.drawTextTransparent(label_x, row_y, "Type:", rgb(0x60, 0x60, 0x60));
    const name = entry.name[0..entry.name_len];
    const ext = getExtension(name);
    if (entry.is_directory) {
        fb.drawTextTransparent(value_x, row_y, "File folder", rgb(0x18, 0x18, 0x18));
    } else {
        var type_buf: [32]u8 = undefined;
        const type_str = std.fmt.bufPrint(&type_buf, "{s} File", .{ext}) catch "File";
        fb.drawTextTransparent(value_x, row_y, type_str, rgb(0x18, 0x18, 0x18));
    }
    row_y += row_h;
    
    // Date modified
    fb.drawTextTransparent(label_x, row_y, "Modified:", rgb(0x60, 0x60, 0x60));
    fb.drawTextTransparent(value_x, row_y, entry.date[0..entry.date_len], rgb(0x18, 0x18, 0x18));
    row_y += row_h;
    
    // Date created (if available)
    fb.drawTextTransparent(label_x, row_y, "Created:", rgb(0x60, 0x60, 0x60));
    fb.drawTextTransparent(value_x, row_y, "--", rgb(0x18, 0x18, 0x18));
    row_y += row_h;
    
    // Attributes
    fb.drawTextTransparent(label_x, row_y, "Attributes:", rgb(0x60, 0x60, 0x60));
    const attr_str = if (entry.is_directory) "D" else "";
    fb.drawTextTransparent(value_x, row_y, attr_str, rgb(0x18, 0x18, 0x18));
}

// ── Helper Functions ──────────────────────────────────────────────────────────

fn getExtension(name: []const u8) []const u8 {
    for (name, 0..) |c, idx| {
        if (c == '.') {
            return name[idx + 1..];
        }
    }
    return "";
}

fn isImageExtension(ext: []const u8) bool {
    const images = [_][]const u8{ "jpg", "jpeg", "png", "gif", "bmp", "ico" };
    const ext_lower = std.ascii.lowerString(&[16]u8{}, ext);
    for (images) |img| {
        if (std.mem.eql(u8, ext_lower[0..ext.len], img)) {
            return true;
        }
    }
    return false;
}

fn isTextExtension(ext: []const u8) bool {
    const texts = [_][]const u8{ "txt", "md", "log", "ini", "cfg", "xml", "json" };
    const ext_lower = std.ascii.lowerString(&[16]u8{}, ext);
    for (texts) |txt| {
        if (std.mem.eql(u8, ext_lower[0..ext.len], txt)) {
            return true;
        }
    }
    return false;
}
