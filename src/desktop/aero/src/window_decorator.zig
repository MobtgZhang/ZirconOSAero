//! Aero Window Decorator
//! Draws window chrome with glass titlebar, gradient borders,
//! and caption buttons (minimize, maximize/restore, close).
//! Active windows get full glass effect; inactive windows use muted tint.

const theme = @import("theme.zig");
const dwm = @import("dwm.zig");

pub const WindowState = enum {
    normal,
    maximized,
    minimized,
};

pub const CaptionButton = enum {
    none,
    minimize,
    maximize,
    close,
};

pub const WindowChrome = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 640,
    height: i32 = 480,
    title: [128]u8 = [_]u8{0} ** 128,
    title_len: u8 = 0,
    active: bool = true,
    state: WindowState = .normal,
    resizable: bool = true,

    pub fn getTitlebarTint(self: *const WindowChrome) u32 {
        return if (self.active) theme.titlebar_glass_tint else theme.titlebar_inactive_tint;
    }

    pub fn getTitlebarText(self: *const WindowChrome) u32 {
        return if (self.active) theme.titlebar_text else theme.titlebar_inactive_text;
    }

    pub fn getBorderColor(self: *const WindowChrome) u32 {
        return if (self.active) theme.window_border else theme.window_border_inactive;
    }
};

pub fn hitTestCaption(chrome: *const WindowChrome, click_x: i32, click_y: i32) CaptionButton {
    const tb_h = theme.Layout.titlebar_height;
    const btn_sz = theme.Layout.btn_size;

    if (click_y < chrome.y or click_y >= chrome.y + tb_h) return .none;

    const close_x = chrome.x + chrome.width - btn_sz - 4;
    const max_x = close_x - btn_sz - 2;
    const min_x = max_x - btn_sz - 2;

    if (click_x >= close_x and click_x < close_x + btn_sz and
        click_y >= chrome.y + 2 and click_y < chrome.y + 2 + btn_sz)
    {
        return .close;
    }
    if (click_x >= max_x and click_x < max_x + btn_sz and
        click_y >= chrome.y + 2 and click_y < chrome.y + 2 + btn_sz)
    {
        return .maximize;
    }
    if (click_x >= min_x and click_x < min_x + btn_sz and
        click_y >= chrome.y + 2 and click_y < chrome.y + 2 + btn_sz)
    {
        return .minimize;
    }
    return .none;
}

pub fn renderTitlebarGlass(
    fb_addr: usize,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    fb_bpp: u8,
    chrome: *const WindowChrome,
) void {
    if (chrome.active) {
        dwm.renderGlassRegion(
            fb_addr,
            fb_width,
            fb_height,
            fb_pitch,
            fb_bpp,
            chrome.x,
            chrome.y,
            chrome.width,
            theme.Layout.titlebar_height,
            chrome.getTitlebarTint(),
            0,
        );
    }
}

pub fn renderWindowShadow(
    fb_addr: usize,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    fb_bpp: u8,
    chrome: *const WindowChrome,
) void {
    if (chrome.active and chrome.state == .normal) {
        dwm.renderSoftShadow(
            fb_addr,
            fb_width,
            fb_height,
            fb_pitch,
            fb_bpp,
            chrome.x,
            chrome.y,
            chrome.width,
            chrome.height,
        );
    }
}
