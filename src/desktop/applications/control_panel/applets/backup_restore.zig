// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/backup_restore.zig
// Purpose: Backup and Restore Center - backup/restore configuration applet
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

pub const BackupState = struct {
    backup_enabled: bool = false,
    last_backup_time: u64 = 0,
    backup_destination: [64]u8 = undefined,
    backup_destination_len: usize = 0,
    backup_frequency: BackupFrequency = .manual,
    scheduled_backup_time: u32 = 0,
};

pub const BackupFrequency = enum {
    manual,
    daily,
    weekly,
    monthly,
};

var backup_state: BackupState = .{ .backup_destination_len = 0 };
var hover_set_backup: bool = false;
var hover_restore: bool = false;
var hover_create_system_image: bool = false;
var hover_settings: bool = false;
var show_backup_wizard: bool = false;
var wizard_step: u8 = 0;

pub fn getState() *BackupState {
    return &backup_state;
}

pub fn createWindow(x_pos: i32, y_pos: i32) applet_base.ControlPanelApplet {
    return applet_base.ControlPanelApplet.create(.backup_restore, x_pos, y_pos, 560, 450);
}

pub fn render(backup: *const applet_base.ControlPanelApplet) void {
    backup.renderCaptionBar("Backup and Restore");
    
    const cx = backup.x + 8;
    const cy = backup.y + 40;
    const cw = backup.width - 16;
    const ch = backup.height - 48;
    
    // Background
    fb.fillRect(cx, cy, cw, ch, rgb(0xF0, 0xF4, 0xF8));
    
    if (show_backup_wizard) {
        renderBackupWizard(cx, cy, cw, ch);
        return;
    }
    
    // Title
    fb.drawTextTransparent(cx + 10, cy + 10, "Backup your files and settings", rgb(0x18, 0x18, 0x20));
    
    // Main backup section
    const main_y = cy + 45;
    const main_h: i32 = 100;
    const main_bg = if (hover_set_backup) rgb(0xE8, 0xF0, 0xF8) else rgb(0xF8, 0xFA, 0xFC);
    fb.fillRect(cx + 10, main_y, cw - 20, main_h, main_bg);
    fb.draw3DRect(cx + 10, main_y, cw - 20, main_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
    
    // Backup icon
    fb.fillRect(cx + 20, main_y + 15, 60, 60, rgb(0xD8, 0xE8, 0xF8));
    fb.drawRect(cx + 28, main_y + 25, 44, 40, rgb(0x40, 0x80, 0xC0));
    fb.fillRect(cx + 30, main_y + 27, 40, 4, rgb(0x60, 0xA0, 0xE0));
    fb.fillRect(cx + 30, main_y + 33, 30, 4, rgb(0x60, 0xA0, 0xE0));
    fb.fillRect(cx + 30, main_y + 39, 35, 4, rgb(0x60, 0xA0, 0xE0));
    
    fb.drawTextTransparent(cx + 90, main_y + 15, "Set up backup", rgb(0x20, 0x40, 0x80));
    fb.drawTextTransparent(cx + 90, main_y + 35, "Create a backup copy of your files", rgb(0x50, 0x50, 0x58));
    
    if (backup_state.backup_enabled) {
        var status_buf: [128]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "Last backup: {d} files", .{@as(u32, @intCast(backup_state.last_backup_time))}) catch "Last backup: never";
        fb.drawTextTransparent(cx + 90, main_y + 55, status, rgb(0x40, 0x80, 0x40));
    } else {
        fb.drawTextTransparent(cx + 90, main_y + 55, "No backup configured", rgb(0xA0, 0x50, 0x50));
    }
    
    // Set up backup button
    const btn_x = cx + cw - 150;
    const btn_y = main_y + 35;
    const btn_w: i32 = 130;
    const btn_h: i32 = 30;
    const btn_bg = if (hover_set_backup) rgb(0x60, 0x90, 0xC0) else rgb(0x40, 0x70, 0xA0);
    fb.fillRect(btn_x, btn_y, btn_w, btn_h, btn_bg);
    fb.draw3DRect(btn_x, btn_y, btn_w, btn_h, rgb(0x30, 0x60, 0x90), rgb(0x80, 0xB0, 0xE0));
    fb.drawTextTransparent(btn_x + 35, btn_y + 8, "Set up backup", rgb(0xFF, 0xFF, 0xFF));
    
    // Restore section
    const restore_y = main_y + main_h + 15;
    const restore_h: i32 = 80;
    const restore_bg = if (hover_restore) rgb(0xE8, 0xF0, 0xF8) else rgb(0xF8, 0xFA, 0xFC);
    fb.fillRect(cx + 10, restore_y, cw - 20, restore_h, restore_bg);
    fb.draw3DRect(cx + 10, restore_y, cw - 20, restore_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
    
    // Restore icon
    fb.fillRect(cx + 20, restore_y + 12, 50, 50, rgb(0xE8, 0xF0, 0xE0));
    fb.drawRect(cx + 30, restore_y + 22, 30, 30, rgb(0x40, 0x90, 0x40));
    fb.drawTextTransparent(cx + 35, restore_y + 28, "RST", rgb(0x30, 0x70, 0x30));
    
    fb.drawTextTransparent(cx + 90, restore_y + 12, "Restore", rgb(0x20, 0x40, 0x80));
    fb.drawTextTransparent(cx + 90, restore_y + 32, "Restore files from a backup", rgb(0x50, 0x50, 0x58));
    
    // Restore button
    const rst_btn_bg = if (hover_restore) rgb(0x60, 0x90, 0xC0) else rgb(0x40, 0x70, 0xA0);
    fb.fillRect(btn_x, restore_y + 25, btn_w, btn_h, rst_btn_bg);
    fb.draw3DRect(btn_x, restore_y + 25, btn_w, btn_h, rgb(0x30, 0x60, 0x90), rgb(0x80, 0xB0, 0xE0));
    fb.drawTextTransparent(btn_x + 40, restore_y + 33, "Restore", rgb(0xFF, 0xFF, 0xFF));
    
    // System image section
    const sys_y = restore_y + restore_h + 15;
    const sys_h: i32 = 70;
    const sys_bg = if (hover_create_system_image) rgb(0xE8, 0xF0, 0xF8) else rgb(0xF8, 0xFA, 0xFC);
    fb.fillRect(cx + 10, sys_y, cw - 20, sys_h, sys_bg);
    fb.draw3DRect(cx + 10, sys_y, cw - 20, sys_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
    
    fb.fillRect(cx + 20, sys_y + 10, 50, 50, rgb(0xF0, 0xE8, 0xD8));
    fb.drawRect(cx + 28, sys_y + 18, 34, 34, rgb(0xA0, 0x80, 0x60));
    
    fb.drawTextTransparent(cx + 90, sys_y + 8, "Create a system image", rgb(0x20, 0x40, 0x80));
    fb.drawTextTransparent(cx + 90, sys_y + 28, "Create a backup of your system files", rgb(0x50, 0x50, 0x58));
    fb.drawTextTransparent(cx + 90, sys_y + 48, "(Requires administrator privileges)", rgb(0x80, 0x80, 0x80));
    
    // System image button
    const sys_btn_bg = if (hover_create_system_image) rgb(0xD0, 0xC0, 0xA0) else rgb(0xC0, 0xB0, 0x90);
    fb.fillRect(btn_x, sys_y + 20, btn_w, btn_h, sys_btn_bg);
    fb.draw3DRect(btn_x, sys_y + 20, btn_w, btn_h, rgb(0xA0, 0x90, 0x70), rgb(0xE0, 0xD0, 0xB0));
    fb.drawTextTransparent(btn_x + 25, sys_y + 28, "Create Image", rgb(0xFF, 0xFF, 0xFF));
    
    // Settings section
    const settings_y = sys_y + sys_h + 15;
    const settings_bg = if (hover_settings) rgb(0xE8, 0xF0, 0xF8) else rgb(0xF8, 0xFA, 0xFC);
    fb.fillRect(cx + 10, settings_y, cw - 20, 50, settings_bg);
    fb.draw3DRect(cx + 10, settings_y, cw - 20, 50, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
    
    fb.drawTextTransparent(cx + 20, settings_y + 18, "Backup settings", rgb(0x20, 0x40, 0x80));
    
    const freq_str: []const u8 = switch (backup_state.backup_frequency) {
        .manual => "Manual",
        .daily => "Daily",
        .weekly => "Weekly",
        .monthly => "Monthly",
    };
    fb.drawTextTransparent(cx + 130, settings_y + 18, freq_str, rgb(0x40, 0x40, 0x50));
}

fn renderBackupWizard(cx: i32, cy: i32, cw: i32, ch: i32) void {
    fb.drawTextTransparent(cx + 10, cy + 10, "Backup Wizard", rgb(0x18, 0x18, 0x20));
    
    const step_y = cy + 45;
    
    switch (wizard_step) {
        0 => {
            // Step 1: Select backup destination
            fb.drawTextTransparent(cx + 10, step_y, "Step 1: Where do you want to save the backup?", rgb(0x20, 0x40, 0x80));
            
            // Destination options
            const opt_y = step_y + 40;
            const opt_h: i32 = 50;
            fb.fillRect(cx + 10, opt_y, cw - 20, opt_h, rgb(0xF8, 0xFA, 0xFC));
            fb.draw3DRect(cx + 10, opt_y, cw - 20, opt_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(cx + 20, opt_y + 18, "On a hard disk or network location", rgb(0x20, 0x40, 0x80));
            
            fb.fillRect(cx + 10, opt_y + opt_h + 10, cw - 20, opt_h, rgb(0xF8, 0xFA, 0xFC));
            fb.draw3DRect(cx + 10, opt_y + opt_h + 10, cw - 20, opt_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(cx + 20, opt_y + opt_h + 28, "On DVDs or other removable media", rgb(0x20, 0x40, 0x80));
            
            // Current destination
            if (backup_state.backup_destination_len > 0) {
                fb.drawTextTransparent(cx + 10, step_y + 200, "Current destination:", rgb(0x50, 0x50, 0x60));
                fb.drawTextTransparent(cx + 10, step_y + 220, backup_state.backup_destination[0..backup_state.backup_destination_len], rgb(0x30, 0x30, 0x40));
            }
        },
        1 => {
            // Step 2: What to backup
            fb.drawTextTransparent(cx + 10, step_y, "Step 2: What do you want to back up?", rgb(0x20, 0x40, 0x80));
            
            fb.fillRect(cx + 10, step_y + 40, cw - 20, 60, rgb(0xF8, 0xFA, 0xFC));
            fb.draw3DRect(cx + 10, step_y + 40, cw - 20, 60, rgb(0x00, 0xA0, 0x40), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(cx + 20, step_y + 55, "Let Windows choose (recommended)", rgb(0x20, 0x60, 0x40));
            fb.drawTextTransparent(cx + 30, step_y + 75, "Includes user files and system settings", rgb(0x60, 0x60, 0x60));
            
            fb.fillRect(cx + 10, step_y + 110, cw - 20, 60, rgb(0xF8, 0xFA, 0xFC));
            fb.draw3DRect(cx + 10, step_y + 110, cw - 20, 60, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(cx + 20, step_y + 125, "Let me choose", rgb(0x20, 0x40, 0x80));
            fb.drawTextTransparent(cx + 30, step_y + 145, "Select individual folders and drives", rgb(0x60, 0x60, 0x60));
        },
        2 => {
            // Step 3: Schedule
            fb.drawTextTransparent(cx + 10, step_y, "Step 3: How often do you want to create backups?", rgb(0x20, 0x40, 0x80));
            
            const sched_y = step_y + 50;
            const sched_h: i32 = 40;
            
            const manual_sel = backup_state.backup_frequency == .manual;
            const manual_bg = if (manual_sel) rgb(0xE0, 0xF0, 0xE0) else rgb(0xF8, 0xFA, 0xFC);
            fb.fillRect(cx + 10, sched_y, cw - 20, sched_h, manual_bg);
            fb.draw3DRect(cx + 10, sched_y, cw - 20, sched_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(cx + 20, sched_y + 12, "Manual (default)", rgb(0x20, 0x40, 0x80));
            
            fb.fillRect(cx + 10, sched_y + sched_h + 5, cw - 20, sched_h, rgb(0xF8, 0xFA, 0xFC));
            fb.draw3DRect(cx + 10, sched_y + sched_h + 5, cw - 20, sched_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(cx + 20, sched_y + sched_h + 17, "Daily at 7:00 PM", rgb(0x20, 0x40, 0x80));
            
            fb.fillRect(cx + 10, sched_y + 2 * (sched_h + 5), cw - 20, sched_h, rgb(0xF8, 0xFA, 0xFC));
            fb.draw3DRect(cx + 10, sched_y + 2 * (sched_h + 5), cw - 20, sched_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(cx + 20, sched_y + 2 * (sched_h + 5) + 17, "Weekly on Sunday at 7:00 PM", rgb(0x20, 0x40, 0x80));
        },
        3 => {
            // Summary
            fb.drawTextTransparent(cx + 10, step_y, "Review your backup settings:", rgb(0x20, 0x40, 0x80));
            
            fb.drawTextTransparent(cx + 10, step_y + 50, "Backup destination:", rgb(0x50, 0x50, 0x60));
            if (backup_state.backup_destination_len > 0) {
                fb.drawTextTransparent(cx + 10, step_y + 70, backup_state.backup_destination[0..backup_state.backup_destination_len], rgb(0x30, 0x30, 0x40));
            } else {
                fb.drawTextTransparent(cx + 10, step_y + 70, "(Not specified)", rgb(0xA0, 0x50, 0x50));
            }
            
            fb.drawTextTransparent(cx + 10, step_y + 100, "Backup contents:", rgb(0x50, 0x50, 0x60));
            fb.drawTextTransparent(cx + 10, step_y + 120, "User files and system settings", rgb(0x30, 0x30, 0x40));
            
            fb.drawTextTransparent(cx + 10, step_y + 150, "Backup frequency:", rgb(0x50, 0x50, 0x60));
            const freq_str: []const u8 = switch (backup_state.backup_frequency) {
                .manual => "Manual",
                .daily => "Daily at 7:00 PM",
                .weekly => "Weekly on Sunday at 7:00 PM",
                .monthly => "Monthly",
            };
            fb.drawTextTransparent(cx + 10, step_y + 170, freq_str, rgb(0x30, 0x30, 0x40));
            
            // Warning
            fb.fillRect(cx + 10, step_y + 210, cw - 20, 50, rgb(0xFF, 0xF0, 0xE0));
            fb.draw3DRect(cx + 10, step_y + 210, cw - 20, 50, rgb(0xE0, 0xC0, 0xA0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(cx + 20, step_y + 225, "Note: This is a stub implementation. Real backup functionality", rgb(0x80, 0x40, 0x20));
            fb.drawTextTransparent(cx + 20, step_y + 240, "requires VSS (Volume Shadow Copy) support.", rgb(0x80, 0x40, 0x20));
        },
        else => {},
    }
    
    // Navigation buttons
    const btn_y = cy + ch - 45;
    const btn_w: i32 = 100;
    const btn_h: i32 = 30;
    
    if (wizard_step > 0) {
        fb.fillRect(cx + 10, btn_y, btn_w, btn_h, rgb(0xE0, 0xE0, 0xE0));
        fb.draw3DRect(cx + 10, btn_y, btn_w, btn_h, rgb(0xB0, 0xB0, 0xB0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(cx + 35, btn_y + 8, "< Back", rgb(0x40, 0x40, 0x50));
    }
    
    const next_text: []const u8 = if (wizard_step == 3) "Finish" else "Next >";
    const next_x = cx + cw - btn_w - 10;
    fb.fillRect(next_x, btn_y, btn_w, btn_h, rgb(0x40, 0x70, 0xA0));
    fb.draw3DRect(next_x, btn_y, btn_w, btn_h, rgb(0x30, 0x50, 0x80), rgb(0x60, 0x90, 0xC0));
    fb.drawTextTransparent(next_x + 25, btn_y + 8, next_text, rgb(0xFF, 0xFF, 0xFF));
    
    // Cancel button
    fb.fillRect(cx + cw - 2 * btn_w - 20, btn_y, btn_w, btn_h, rgb(0xE0, 0xE0, 0xE0));
    fb.draw3DRect(cx + cw - 2 * btn_w - 20, btn_y, btn_w, btn_h, rgb(0xB0, 0xB0, 0xB0), rgb(0xFF, 0xFF, 0xFF));
    fb.drawTextTransparent(cx + cw - 2 * btn_w - 5, btn_y + 8, "Cancel", rgb(0x40, 0x40, 0x50));
}

pub fn handleClick(backup: *const applet_base.ControlPanelApplet, px: i32, py: i32) void {
    const cx = backup.x + 8;
    const cy = backup.y + 40;
    const cw = backup.width - 16;
    const btn_x = cx + cw - 150;
    const btn_y = cy + 80;
    const btn_w: i32 = 130;
    const btn_h: i32 = 30;
    
    if (show_backup_wizard) {
        const nav_btn_y = backup.y + backup.height - 45;
        
        // Cancel button
        if (px >= cx + cw - 2 * btn_w - 20 and px < cx + cw - btn_w - 20 and
            py >= nav_btn_y and py < nav_btn_y + 30) {
            show_backup_wizard = false;
            wizard_step = 0;
            return;
        }
        
        // Next/Finish button
        if (px >= cx + cw - btn_w - 10 and px < cx + cw - 10 and
            py >= nav_btn_y and py < nav_btn_y + 30) {
            if (wizard_step < 3) {
                wizard_step += 1;
            } else {
                // Finish - save backup configuration
                backup_state.backup_enabled = true;
                backup_state.last_backup_time = 0;
                show_backup_wizard = false;
                wizard_step = 0;
            }
            return;
        }
        
        // Back button
        if (wizard_step > 0 and px >= cx + 10 and px < cx + 110 and
            py >= nav_btn_y and py < nav_btn_y + 30) {
            if (wizard_step > 0) wizard_step -= 1;
            return;
        }
        return;
    }
    
    // Set up backup button
    if (px >= btn_x and px < btn_x + btn_w and py >= btn_y and py < btn_y + btn_h) {
        show_backup_wizard = true;
        wizard_step = 0;
        return;
    }
    
    // Restore button
    const restore_y = btn_y + 115;
    if (px >= btn_x and px < btn_x + btn_w and py >= restore_y and py < restore_y + btn_h) {
        builtin_apps.launch(.system_restore);
        return;
    }
    
    // System image button
    const sys_y = restore_y + 85;
    if (px >= btn_x and px < btn_x + btn_w and py >= sys_y and py < sys_y + btn_h) {
        // Show system image dialog (stub)
        return;
    }
}

pub fn handleMouseMove(backup: *const applet_base.ControlPanelApplet, px: i32, py: i32) void {
    if (show_backup_wizard) return;
    
    const cx = backup.x + 8;
    const cy = backup.y + 40;
    const cw = backup.width - 16;
    const btn_x = cx + cw - 150;
    
    const main_y = cy + 45;
    hover_set_backup = (px >= btn_x and px < btn_x + 130 and py >= main_y + 35 and py < main_y + 65);
    
    const restore_y = main_y + 115;
    hover_restore = (px >= btn_x and px < btn_x + 130 and py >= restore_y + 25 and py < restore_y + 55);
    
    const sys_y = restore_y + 85;
    hover_create_system_image = (px >= btn_x and px < btn_x + 130 and py >= sys_y + 20 and py < sys_y + 50);
    
    hover_settings = (px >= cx + 10 and px < cx + cw - 10 and py >= sys_y + 120 and py < sys_y + 170);
}
