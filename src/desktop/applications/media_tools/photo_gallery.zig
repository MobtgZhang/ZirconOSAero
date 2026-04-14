// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/media_tools/photo_gallery.zig
// Purpose: Photo Gallery - Image browser and viewer
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const PhotoItem = struct {
    id: u32,
    name: [64]u8,
    name_len: usize,
    path: [128]u8,
    path_len: usize,
    width: u32,
    height: u32,
    date_taken: [32]u8,
    date_len: usize,
    rating: u8,
    is_favorite: bool,
};

pub const GalleryView = enum {
    thumbnails,
    single_photo,
};

pub const PhotoGalleryApp = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    
    current_view: GalleryView,
    photos: [30]PhotoItem,
    photo_count: usize,
    selected_photo: i32,
    thumbnails_per_row: i32,
    
    // Single photo viewer state
    zoom_level: f32,
    pan_x: i32,
    pan_y: i32,
    
    // UI state
    hover_prev: bool,
    hover_next: bool,
    hover_zoom_in: bool,
    hover_zoom_out: bool,
    hover_back: bool,
    hover_slideshow: bool,
    hover_favorite: bool,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) PhotoGalleryApp {
        var app: PhotoGalleryApp = .{
            .x = x_pos, .y = y_pos,
            .width = 800, .height = 550,
            .visible = true, .caption_hover = .none,
            .current_view = .thumbnails,
            .photos = undefined, .photo_count = 0,
            .selected_photo = -1,
            .thumbnails_per_row = 4,
            .zoom_level = 1.0,
            .pan_x = 0, .pan_y = 0,
            .hover_prev = false, .hover_next = false,
            .hover_zoom_in = false, .hover_zoom_out = false,
            .hover_back = false, .hover_slideshow = false,
            .hover_favorite = false,
        };
        
        app.initSamplePhotos();
        return app;
    }

    fn initSamplePhotos(app: *PhotoGalleryApp) void {
        const samples = [_]struct { name: []const u8, w: u32, h: u32 }{
            .{ .name = "IMG_0001.jpg", .w = 1920, .h = 1080 },
            .{ .name = "IMG_0002.jpg", .w = 1600, .h = 1200 },
            .{ .name = "IMG_0003.png", .w = 1280, .h = 720 },
            .{ .name = "Screenshot.png", .w = 1366, .h = 768 },
            .{ .name = "Photo_01.bmp", .w = 800, .h = 600 },
            .{ .name = "Wallpaper.jpg", .w = 2560, .h = 1440 },
            .{ .name = "Portrait.png", .w = 1200, .h = 1600 },
            .{ .name = "Landscape.jpg", .w = 2560, .h = 1080 },
        };
        
        app.photo_count = 0;
        for (samples, 0..) |s, i| {
            var photo = &app.photos[i];
            photo.id = @as(u32, @intCast(i));
            
            @memcpy(photo.name[0..s.name.len], s.name);
            photo.name_len = s.name.len;
            
            @memcpy(photo.path[0..s.name.len], "C:\\Pictures\\");
            photo.path_len = 12;
            @memcpy(photo.path[12..][0..s.name.len], s.name);
            photo.path_len += s.name.len;
            
            photo.width = s.w;
            photo.height = s.h;
            
            @memcpy(photo.date_taken[0..5], "Apr ");
            photo.date_taken[4] = '0' + @as(u8, @intCast((i % 9) + 1));
            photo.date_taken[5] = ',';
            @memcpy(photo.date_taken[6..][0..5], " 2026");
            photo.date_len = 11;
            
            photo.rating = @as(u8, @intCast(i % 5));
            photo.is_favorite = (i == 2);
            
            app.photo_count += 1;
        }
    }

    pub fn render(app: *const PhotoGalleryApp, t: *const theme_mod.ThemeColors) void {
        if (!app.visible) return;
        _ = t;

        const wx = app.x;
        const wy = app.y;
        const ww = app.width;
        const wh = app.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x20, 0x20, 0x30), rgb(0x30, 0x30, 0x40));
        fb.drawTextTransparent(wx + 8, wy + 6, "Photo Gallery", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (app.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        switch (app.current_view) {
            .thumbnails => app.renderThumbnailView(wx, wy, ww, wh),
            .single_photo => app.renderSinglePhotoView(wx, wy, ww, wh),
        }
    }

    fn renderThumbnailView(app: *const PhotoGalleryApp, wx: i32, wy: i32, ww: i32, wh: i32) void {
        // Toolbar
        const toolbar_y = wy + 35;
        fb.fillRect(wx, toolbar_y, ww, 40, rgb(0xF0, 0xF0, 0xF0));
        fb.drawHLine(wx, toolbar_y + 40, ww, rgb(0xCC, 0xCC, 0xCC));
        
        // Info text
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d} items", .{app.photo_count}) catch "";
        fb.drawTextTransparent(wx + 10, toolbar_y + 12, count_str, rgb(0x40, 0x40, 0x50));
        
        // Slideshow button
        const ss_x = wx + ww - 90;
        const ss_bg = if (app.hover_slideshow) rgb(0x60, 0x90, 0xC0) else rgb(0x40, 0x70, 0xA0);
        fb.fillRect(ss_x, toolbar_y + 8, 75, 26, ss_bg);
        fb.draw3DRect(ss_x, toolbar_y + 8, 75, 26, rgb(0x30, 0x60, 0x90), rgb(0x80, 0xB0, 0xE0));
        fb.drawTextTransparent(ss_x + 15, toolbar_y + 16, "Slideshow", rgb(0xFF, 0xFF, 0xFF));
        
        // Thumbnail grid
        const grid_y = toolbar_y + 45;

        const thumb_w: i32 = 160;
        const thumb_h: i32 = 130;
        const gap_x: i32 = 10;
        const gap_y: i32 = 10;
        
        const cols = @divTrunc(ww - 20, thumb_w + gap_x);
        const thumb_per_row = @max(1, cols);
        
        var row: i32 = 0;
        var col: i32 = 0;
        
        for (0..app.photo_count) |i| {
            const thumb_x = wx + 10 + col * (thumb_w + gap_x);
            const thumb_y = grid_y + row * (thumb_h + gap_y);
            
            if (thumb_y > wy + wh - 50) break;
            if (thumb_x > wx + ww - thumb_w) {
                col = 0;
                row += 1;
                continue;
            }
            
            const is_selected = @as(i32, @intCast(i)) == app.selected_photo;
            
            // Thumbnail frame
            const frame_color = if (is_selected) rgb(0x00, 0x78, 0xD4) else rgb(0xD0, 0xD0, 0xD8);
            fb.fillRect(thumb_x - 2, thumb_y - 2, thumb_w + 4, thumb_h + 4, frame_color);
            fb.fillRect(thumb_x, thumb_y, thumb_w, thumb_h, rgb(0xE8, 0xE8, 0xF0));
            
            // Placeholder image
            const photo = app.photos[i];
            fb.fillRect(thumb_x + 10, thumb_y + 10, thumb_w - 20, thumb_h - 40, rgb(0xC0, 0xD0, 0xE0));
            
            // Image icon
            fb.drawRect(thumb_x + 30, thumb_y + 25, thumb_w - 60, thumb_h - 60, rgb(0x90, 0xA0, 0xB0));
            fb.drawTextTransparent(thumb_x + thumb_w/2 - 30, thumb_y + thumb_h/2 - 20, "[Image]", rgb(0x70, 0x80, 0x90));
            
            // Filename
            fb.drawTextTransparent(thumb_x + 5, thumb_y + thumb_h - 28, photo.name[0..photo.name_len], rgb(0x20, 0x20, 0x30));
            
            // Dimensions
            var dim_buf: [32]u8 = undefined;
            const dim_str = std.fmt.bufPrint(&dim_buf, "{d}x{d}", .{ photo.width, photo.height }) catch "";
            fb.drawTextTransparent(thumb_x + 5, thumb_y + thumb_h - 14, dim_str, rgb(0x80, 0x80, 0x90));
            
            // Rating stars
            const star_y = thumb_y + 12;
            for (0..5) |s| {
                const star_char: u8 = if (s < photo.rating) '*' else '-';
                var star_buf: [2]u8 = .{ star_char, 0 };
                const star_color = if (s < photo.rating) rgb(0xFF, 0xC0, 0x00) else rgb(0xC0, 0xC0, 0xC0);
                fb.drawTextTransparent(thumb_x + thumb_w - 55 + @as(i32, @intCast(s)) * 10, star_y, &star_buf, star_color);
            }
            
            // Favorite indicator
            if (photo.is_favorite) {
                fb.drawTextTransparent(thumb_x + 5, thumb_y + 5, "*", rgb(0xFF, 0xC0, 0x00));
            }
            
            col += 1;
            if (col >= thumb_per_row) {
                col = 0;
                row += 1;
            }
        }
    }

    fn renderSinglePhotoView(app: *const PhotoGalleryApp, wx: i32, wy: i32, ww: i32, wh: i32) void {
        // Back button
        const back_y = wy + 38;
        fb.fillRect(wx + 10, back_y, 60, 28, if (app.hover_back) rgb(0xD0, 0xD0, 0xD0) else rgb(0xE8, 0xE8, 0xE8));
        fb.draw3DRect(wx + 10, back_y, 60, 28, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(wx + 25, back_y + 8, "Back", rgb(0x30, 0x30, 0x40));
        
        // Navigation buttons
        fb.fillRect(wx + 80, back_y, 28, 28, if (app.hover_prev) rgb(0xD0, 0xD0, 0xD0) else rgb(0xE8, 0xE8, 0xE8));
        fb.draw3DRect(wx + 80, back_y, 28, 28, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(wx + 90, back_y + 8, "<", rgb(0x30, 0x30, 0x40));
        
        fb.fillRect(wx + 115, back_y, 28, 28, if (app.hover_next) rgb(0xD0, 0xD0, 0xD0) else rgb(0xE8, 0xE8, 0xE8));
        fb.draw3DRect(wx + 115, back_y, 28, 28, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(wx + 125, back_y + 8, ">", rgb(0x30, 0x30, 0x40));
        
        // Photo info
        if (app.selected_photo >= 0) {
            const idx = @as(usize, @intCast(app.selected_photo));
            if (idx < app.photo_count) {
                const photo = app.photos[idx];
                
                // Photo name
                fb.drawTextTransparent(wx + 160, back_y + 8, photo.name[0..photo.name_len], rgb(0x30, 0x30, 0x40));
                
                // Favorite button
                const fav_bg = if (app.hover_favorite)
                    if (photo.is_favorite) rgb(0xFF, 0xE0, 0x00) else rgb(0xFF, 0xFF, 0xC0)
                else
                    if (photo.is_favorite) rgb(0xFF, 0xD0, 0x00) else rgb(0xF0, 0xF0, 0xE0);
                fb.fillRect(wx + ww - 90, back_y, 80, 28, fav_bg);
                fb.draw3DRect(wx + ww - 90, back_y, 80, 28, rgb(0xC0, 0xC0, 0xA0), rgb(0xFF, 0xFF, 0xE0));
                fb.drawTextTransparent(wx + ww - 75, back_y + 8, if (photo.is_favorite) "Favorited" else "Favorite", rgb(0x40, 0x40, 0x40));
            }
        }
        
        // Zoom controls
        const zoom_y = back_y + 40;
        fb.fillRect(wx + 10, zoom_y, 28, 28, if (app.hover_zoom_out) rgb(0xD0, 0xD0, 0xD0) else rgb(0xE8, 0xE8, 0xE8));
        fb.draw3DRect(wx + 10, zoom_y, 28, 28, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(wx + 18, zoom_y + 8, "-", rgb(0x30, 0x30, 0x40));
        
        var zoom_buf: [16]u8 = undefined;
        const zoom_str = std.fmt.bufPrint(&zoom_buf, "{d}%", .{@as(i32, @intFromFloat(app.zoom_level * 100))}) catch "";
        fb.drawTextTransparent(wx + 45, zoom_y + 8, zoom_str, rgb(0x40, 0x40, 0x50));
        
        fb.fillRect(wx + 95, zoom_y, 28, 28, if (app.hover_zoom_in) rgb(0xD0, 0xD0, 0xD0) else rgb(0xE8, 0xE8, 0xE8));
        fb.draw3DRect(wx + 95, zoom_y, 28, 28, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(wx + 103, zoom_y + 8, "+", rgb(0x30, 0x30, 0x40));
        
        // Photo display area
        const photo_y = zoom_y + 40;
        const photo_area_h = wh - photo_y + wy - 50;
        
        fb.fillRect(wx + 5, photo_y, ww - 10, photo_area_h, rgb(0x20, 0x20, 0x20));
        
        if (app.selected_photo >= 0) {
            const idx = @as(usize, @intCast(app.selected_photo));
            if (idx < app.photo_count) {
                const photo = app.photos[idx];
                
                // Center the placeholder
                const place_w: i32 = 400;
                const place_h: i32 = 300;
                const place_x = wx + (ww - place_w) / 2 + app.pan_x;
                const place_y = photo_y + (photo_area_h - place_h) / 2 + app.pan_y;
                
                fb.fillRect(place_x, place_y, place_w, place_h, rgb(0x60, 0x70, 0x80));
                fb.drawRect(place_x, place_y, place_w, place_h, rgb(0x80, 0x90, 0xA0));
                fb.drawTextTransparent(place_x + place_w/2 - 50, place_y + place_h/2 - 10, "[Photo Preview]", rgb(0xB0, 0xB0, 0xB0));
                fb.drawTextTransparent(place_x + place_w/2 - 70, place_y + place_h/2 + 10, photo.name[0..photo.name_len], rgb(0x90, 0x90, 0xA0));
            }
        }
        
        // Details panel
        const details_y = wy + wh - 60;
        fb.fillRect(wx, details_y, ww, 60, rgb(0xE8, 0xE8, 0xE8));
        
        if (app.selected_photo >= 0) {
            const idx = @as(usize, @intCast(app.selected_photo));
            if (idx < app.photo_count) {
                const photo = app.photos[idx];
                
                fb.drawTextTransparent(wx + 10, details_y + 10, "Taken:", rgb(0x60, 0x60, 0x70));
                fb.drawTextTransparent(wx + 60, details_y + 10, photo.date_taken[0..photo.date_len], rgb(0x30, 0x30, 0x40));
                
                var dim_buf: [32]u8 = undefined;
                const dim_str = std.fmt.bufPrint(&dim_buf, "Size: {d}x{d}", .{ photo.width, photo.height }) catch "";
                fb.drawTextTransparent(wx + 10, details_y + 30, dim_str, rgb(0x30, 0x30, 0x40));
            }
        }
    }

    pub fn handleMouseMove(app: *PhotoGalleryApp, px: i32, py: i32) void {
        const wx = app.x;
        const wy = app.y;
        const ww = app.width;
        
        if (app.current_view == .thumbnails) {
            app.hover_slideshow = (px >= wx + ww - 90 and px < wx + ww - 15 and py >= wy + 43 and py < wy + 69);
        } else {
            app.hover_back = (px >= wx + 10 and px < wx + 70 and py >= wy + 38 and py < wy + 66);
            app.hover_prev = (px >= wx + 80 and px < wx + 108 and py >= wy + 38 and py < wy + 66);
            app.hover_next = (px >= wx + 115 and px < wx + 143 and py >= wy + 38 and py < wy + 66);
            app.hover_favorite = (px >= wx + ww - 90 and px < wx + ww - 10 and py >= wy + 38 and py < wy + 66);
            app.hover_zoom_in = (px >= wx + 95 and px < wx + 123 and py >= wy + 78 and py < wy + 106);
            app.hover_zoom_out = (px >= wx + 10 and px < wx + 38 and py >= wy + 78 and py < wy + 106);
        }
    }

    pub fn handleClick(app: *PhotoGalleryApp, px: i32, py: i32) void {
        const wx = app.x;
        const wy = app.y;
        const ww = app.width;
        const wh = app.height;
        
        if (app.current_view == .thumbnails) {
            // Calculate which thumbnail was clicked
            const grid_y = wy + 80;
            const thumb_w: i32 = 160;
            const thumb_h: i32 = 130;
            const gap_x: i32 = 10;
            const gap_y: i32 = 10;
            
            const cols = @divTrunc(ww - 20, thumb_w + gap_x);
            const thumb_per_row = @max(1, cols);
            
            if (py >= grid_y and py < wy + wh - 50) {
                const col = @divTrunc(px - wx - 10, thumb_w + gap_x);
                const row = @divTrunc(py - grid_y, thumb_h + gap_y);
                
                if (col >= 0 and row >= 0) {
                    const idx = @as(usize, @intCast(row * thumb_per_row + col));
                    if (idx < app.photo_count) {
                        app.selected_photo = @as(i32, @intCast(idx));
                        app.current_view = .single_photo;
                        app.zoom_level = 1.0;
                        app.pan_x = 0;
                        app.pan_y = 0;
                    }
                }
            }
            
            if (app.hover_slideshow) {
                // Would start slideshow
            }
        } else {
            if (app.hover_back) {
                app.current_view = .thumbnails;
            } else if (app.hover_prev) {
                if (app.selected_photo > 0) {
                    app.selected_photo -= 1;
                }
            } else if (app.hover_next) {
                if (app.selected_photo < @as(i32, @intCast(app.photo_count)) - 1) {
                    app.selected_photo += 1;
                }
            } else if (app.hover_zoom_in) {
                app.zoom_level = @min(4.0, app.zoom_level + 0.25);
            } else if (app.hover_zoom_out) {
                app.zoom_level = @max(0.25, app.zoom_level - 0.25);
            } else if (app.hover_favorite and app.selected_photo >= 0) {
                const idx = @as(usize, @intCast(app.selected_photo));
                app.photos[idx].is_favorite = !app.photos[idx].is_favorite;
            }
        }
    }
};
