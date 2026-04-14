// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/ease_of_access.zig
// Purpose: Ease of Access Center - accessibility options applet
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");
const applet_base = @import("applet_base.zig");
const builtin_apps = @import("../../../../kernel/shell/builtin_apps.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const EaseOfAccessState = struct {
    magnifier_enabled: bool = false,
    magnifier_zoom: i32 = 200,
    narrator_enabled: bool = false,
    osk_enabled: bool = false,
    high_contrast_enabled: bool = false,
    selected_theme: u8 = 0,
};

var eoa_state: EaseOfAccessState = .{};
var hover_magnifier: bool = false;
var hover_narrator: bool = false;
var hover_osk: bool = false;
var hover_contrast: bool = false;
var hover_mouse: bool = false;
var hover_keyboard: bool = false;
var hover_audio: bool = false;

pub fn getState() *EaseOfAccessState {
    return &eoa_state;
}

pub fn createWindow(x_pos: i32, y_pos: i32) applet_base.ControlPanelApplet {
    return applet_base.ControlPanelApplet.create(.ease_of_access, x_pos, y_pos, 520, 420);
}

pub fn render(eoa: *const applet_base.ControlPanelApplet) void {
    eoa.renderCaptionBar("Ease of Access");
    
    const cx = eoa.x + 8;
    const cy = eoa.y + 40;
    const cw = eoa.width - 16;
    const ch = eoa.height - 48;
    
    // Background
    fb.fillRect(cx, cy, cw, ch, rgb(0xF0, 0xF4, 0xF8));
    
    // Title
    fb.drawTextTransparent(cx + 10, cy + 10, "Choose a category to adjust:", rgb(0x18, 0x18, 0x20));
    
    // Magnifier section
    const mag_y = cy + 40;
    const mag_h: i32 = 60;
    const mag_bg = if (hover_magnifier) rgb(0xE8, 0xF0, 0xF8) else rgb(0xF8, 0xFA, 0xFC);
    fb.fillRect(cx + 10, mag_y, cw - 20, mag_h, mag_bg);
    fb.draw3DRect(cx + 10, mag_y, cw - 20, mag_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
    
    // Magnifier icon placeholder
    fb.fillRect(cx + 20, mag_y + 10, 40, 40, rgb(0xD8, 0xE8, 0xF8));
    fb.drawEllipse(cx + 40, mag_y + 30, 18, 18, rgb(0x40, 0x80, 0xC0));
    fb.drawEllipse(cx + 40, mag_y + 30, 12, 12, rgb(0x80, 0xC0, 0xE0));
    
    fb.drawTextTransparent(cx + 70, mag_y + 8, "Magnifier", rgb(0x20, 0x40, 0x80));
    fb.drawTextTransparent(cx + 70, mag_y + 24, "Enlarge text and images on your screen", rgb(0x50, 0x50, 0x58));
    
    // Toggle for magnifier
    const toggle_x = cx + cw - 100;
    const toggle_y = mag_y + 20;
    const toggle_w: i32 = 60;
    const toggle_h: i32 = 24;
    
    if (eoa_state.magnifier_enabled) {
        fb.fillRect(toggle_x, toggle_y, toggle_w, toggle_h, rgb(0x00, 0xA0, 0x40));
        fb.drawTextTransparent(toggle_x + 18, toggle_y + 6, "ON", rgb(0xFF, 0xFF, 0xFF));
    } else {
        fb.fillRect(toggle_x, toggle_y, toggle_w, toggle_h, rgb(0xB0, 0xB0, 0xB0));
        fb.drawTextTransparent(toggle_x + 14, toggle_y + 6, "OFF", rgb(0xFF, 0xFF, 0xFF));
    }
    
    // Narrator section
    const nar_y = mag_y + mag_h + 10;
    const nar_bg = if (hover_narrator) rgb(0xE8, 0xF0, 0xF8) else rgb(0xF8, 0xFA, 0xFC);
    fb.fillRect(cx + 10, nar_y, cw - 20, mag_h, nar_bg);
    fb.draw3DRect(cx + 10, nar_y, cw - 20, mag_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
    
    fb.fillRect(cx + 20, nar_y + 10, 40, 40, rgb(0xE8, 0xE0, 0xF0));
    fb.drawTextTransparent(cx + 30, nar_y + 20, "Aa", rgb(0x80, 0x60, 0xA0));
    
    fb.drawTextTransparent(cx + 70, nar_y + 8, "Narrator", rgb(0x20, 0x40, 0x80));
    fb.drawTextTransparent(cx + 70, nar_y + 24, "Read screen content aloud", rgb(0x50, 0x50, 0x58));
    
    // Toggle for narrator
    if (eoa_state.narrator_enabled) {
        fb.fillRect(toggle_x, nar_y + 20, toggle_w, toggle_h, rgb(0x00, 0xA0, 0x40));
        fb.drawTextTransparent(toggle_x + 18, nar_y + 26, "ON", rgb(0xFF, 0xFF, 0xFF));
    } else {
        fb.fillRect(toggle_x, nar_y + 20, toggle_w, toggle_h, rgb(0xB0, 0xB0, 0xB0));
        fb.drawTextTransparent(toggle_x + 14, nar_y + 26, "OFF", rgb(0xFF, 0xFF, 0xFF));
    }
    
    // On-Screen Keyboard section
    const osk_y = nar_y + mag_h + 10;
    const osk_bg = if (hover_osk) rgb(0xE8, 0xF0, 0xF8) else rgb(0xF8, 0xFA, 0xFC);
    fb.fillRect(cx + 10, osk_y, cw - 20, mag_h, osk_bg);
    fb.draw3DRect(cx + 10, osk_y, cw - 20, mag_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
    
    fb.fillRect(cx + 20, osk_y + 10, 40, 40, rgb(0xE0, 0xE8, 0xE0));
    fb.drawRect(cx + 24, osk_y + 14, 32, 20, rgb(0x60, 0x90, 0x60));
    fb.drawTextTransparent(cx + 28, osk_y + 16, "ABC", rgb(0x40, 0x70, 0x40));
    
    fb.drawTextTransparent(cx + 70, osk_y + 8, "On-Screen Keyboard", rgb(0x20, 0x40, 0x80));
    fb.drawTextTransparent(cx + 70, osk_y + 24, "Type without a physical keyboard", rgb(0x50, 0x50, 0x58));
    
    // Toggle for OSK
    if (eoa_state.osk_enabled) {
        fb.fillRect(toggle_x, osk_y + 20, toggle_w, toggle_h, rgb(0x00, 0xA0, 0x40));
        fb.drawTextTransparent(toggle_x + 18, osk_y + 26, "ON", rgb(0xFF, 0xFF, 0xFF));
    } else {
        fb.fillRect(toggle_x, osk_y + 20, toggle_w, toggle_h, rgb(0xB0, 0xB0, 0xB0));
        fb.drawTextTransparent(toggle_x + 14, osk_y + 26, "OFF", rgb(0xFF, 0xFF, 0xFF));
    }
    
    // High Contrast section
    const con_y = osk_y + mag_h + 10;
    const con_bg = if (hover_contrast) rgb(0xE8, 0xF0, 0xF8) else rgb(0xF8, 0xFA, 0xFC);
    fb.fillRect(cx + 10, con_y, cw - 20, mag_h, con_bg);
    fb.draw3DRect(cx + 10, con_y, cw - 20, mag_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
    
    fb.fillRect(cx + 20, con_y + 10, 40, 40, rgb(0x00, 0x00, 0x00));
    fb.drawTextTransparent(cx + 26, con_y + 20, "ABC", rgb(0xFF, 0xFF, 0x00));
    
    fb.drawTextTransparent(cx + 70, con_y + 8, "High Contrast", rgb(0x20, 0x40, 0x80));
    fb.drawTextTransparent(cx + 70, con_y + 24, "Improve visibility with high contrast colors", rgb(0x50, 0x50, 0x58));
    
    // Toggle for high contrast
    if (eoa_state.high_contrast_enabled) {
        fb.fillRect(toggle_x, con_y + 20, toggle_w, toggle_h, rgb(0x00, 0xA0, 0x40));
        fb.drawTextTransparent(toggle_x + 18, con_y + 26, "ON", rgb(0xFF, 0xFF, 0xFF));
    } else {
        fb.fillRect(toggle_x, con_y + 20, toggle_w, toggle_h, rgb(0xB0, 0xB0, 0xB0));
        fb.drawTextTransparent(toggle_x + 14, con_y + 26, "OFF", rgb(0xFF, 0xFF, 0xFF));
    }
}

pub fn handleClick(eoa: *const applet_base.ControlPanelApplet, px: i32, py: i32) void {
    const cx = eoa.x + 8;
    const cy = eoa.y + 40;
    const cw = eoa.width - 16;
    const toggle_x = cx + cw - 100;
    const toggle_w: i32 = 60;
    const toggle_h: i32 = 24;
    
    const mag_y = cy + 40;
    const nar_y = mag_y + 70;
    const osk_y = nar_y + 70;
    const con_y = osk_y + 70;
    
    // Check toggle buttons
    if (px >= toggle_x and px < toggle_x + toggle_w) {
        if (py >= mag_y + 20 and py < mag_y + 20 + toggle_h) {
            eoa_state.magnifier_enabled = !eoa_state.magnifier_enabled;
            if (eoa_state.magnifier_enabled) {
                builtin_apps.launch(.magnifier);
            }
            return;
        }
        
        if (py >= nar_y + 20 and py < nar_y + 20 + toggle_h) {
            eoa_state.narrator_enabled = !eoa_state.narrator_enabled;
            return;
        }
        
        if (py >= osk_y + 20 and py < osk_y + 20 + toggle_h) {
            eoa_state.osk_enabled = !eoa_state.osk_enabled;
            if (eoa_state.osk_enabled) {
                builtin_apps.launch(.osk);
            }
            return;
        }
        
        if (py >= con_y + 20 and py < con_y + 20 + toggle_h) {
            eoa_state.high_contrast_enabled = !eoa_state.high_contrast_enabled;
            return;
        }
    }
    
    // Check row clicks
    if (py >= mag_y and py < mag_y + 60) {
        builtin_apps.launch(.magnifier);
    } else if (py >= nar_y and py < nar_y + 60) {
        // Launch narrator stub
    } else if (py >= osk_y and py < osk_y + 60) {
        builtin_apps.launch(.osk);
    } else if (py >= con_y and py < con_y + 60) {
        // Toggle high contrast
        eoa_state.high_contrast_enabled = !eoa_state.high_contrast_enabled;
    }
}

pub fn handleMouseMove(eoa: *const applet_base.ControlPanelApplet, px: i32, py: i32) void {
    const cx = eoa.x + 8;
    const cy = eoa.y + 40;
    const cw = eoa.width - 16;
    
    const mag_y = cy + 40;
    const nar_y = mag_y + 70;
    const osk_y = nar_y + 70;
    const con_y = osk_y + 70;
    
    hover_magnifier = (px >= cx + 10 and px < cx + cw - 10 and py >= mag_y and py < mag_y + 60);
    hover_narrator = (px >= cx + 10 and px < cx + cw - 10 and py >= nar_y and py < nar_y + 60);
    hover_osk = (px >= cx + 10 and px < cx + cw - 10 and py >= osk_y and py < osk_y + 60);
    hover_contrast = (px >= cx + 10 and px < cx + cw - 10 and py >= con_y and py < con_y + 60);
}
