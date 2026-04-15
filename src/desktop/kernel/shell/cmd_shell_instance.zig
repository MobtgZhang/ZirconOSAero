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

//! CMD Shell Window Instance Manager (Kernel Path)
//! Manages multiple CMD shell window instances with full GUI support.
//! This module operates in the kernel framebuffer rendering path.
//! 
//! Architecture:
//! - This module manages CMD window state and rendering data
//! - Rendering uses kernel framebuffer directly (fb)
//! - Integration with aero window system is handled separately

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../../kernel/theme/root.zig");
const cmd_shell = @import("../../applications/accessories/cmd_shell.zig");
const builtin_apps = @import("builtin_apps.zig");
const klog = @import("../../../rtl/klog.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme.rgb(r, g, b);
}

/// Caption button types for CMD window
pub const CaptionButtonType = enum { none, minimize, maximize, close };

/// Window state enum (compatible with builtin_apps.WinState)
pub const CmdWindowState = enum(u8) {
    normal = 0,
    minimized = 1,
    maximized = 2,
};

const MAX_CMD_INSTANCES: usize = 4;

/// CMD Window Instance structure
pub const CmdWindowInstance = struct {
    shell: cmd_shell.CmdShell,
    x: i32 = 100,
    y: i32 = 100,
    width: i32 = 700,
    height: i32 = 450,
    visible: bool = false,
    focused: bool = false,
    caption_hover: CaptionButtonType = .none,
    caption_height: i32 = 32,
    state: CmdWindowState = .normal,
    prev_state: CmdWindowState = .normal,
    prev_x: i32 = 100,
    prev_y: i32 = 100,
    prev_w: i32 = 700,
    prev_h: i32 = 450,
    // Link to builtin_apps slot if needed
    slot_index: ?usize = null,
};

var cmd_instances: [MAX_CMD_INSTANCES]CmdWindowInstance = undefined;
var cmd_instance_count: usize = 0;
var cmd_instances_initialized: bool = false;
var focused_cmd_index: ?usize = null;

fn initCmdInstances() void {
    if (cmd_instances_initialized) return;
    for (&cmd_instances, 0..) |*inst, i| {
        inst.* = .{
            .shell = undefined,
            .x = 100,
            .y = 100,
            .width = 700,
            .height = 450,
            .visible = false,
            .focused = false,
            .caption_hover = .none,
            .caption_height = 32,
            .state = .normal,
            .prev_x = 100,
            .prev_y = 100,
            .prev_w = 700,
            .prev_h = 450,
            .slot_index = null,
        };
        _ = i;
    }
    cmd_instances_initialized = true;
}

/// Create a new CMD window and return the instance index
pub fn createCmdWindow() ?usize {
    initCmdInstances();
    
    if (cmd_instance_count >= MAX_CMD_INSTANCES) {
        // Find and close the first visible instance
        for (0..cmd_instance_count) |i| {
            if (cmd_instances[i].visible) {
                destroyCmdWindow(i);
                break;
            }
        }
    }
    
    if (cmd_instance_count >= MAX_CMD_INSTANCES) return null;
    
    const idx = cmd_instance_count;
    const inst = &cmd_instances[idx];
    
    // Calculate position (cascade)
    const offset = @as(i32, @intCast(idx)) * 30;
    inst.x = 100 + offset;
    inst.y = 80 + offset;
    inst.width = 700;
    inst.height = 450;
    inst.visible = true;
    inst.focused = true;
    inst.caption_hover = .none;
    inst.state = .normal;
    inst.prev_x = inst.x;
    inst.prev_y = inst.y;
    inst.prev_w = inst.width;
    inst.prev_h = inst.height;
    
    // Create the CmdShell instance
    inst.shell = cmd_shell.CmdShell.create(inst.x, inst.y);
    
    // Update focus
    if (focused_cmd_index) |old_idx| {
        cmd_instances[old_idx].focused = false;
    }
    focused_cmd_index = idx;
    
    cmd_instance_count += 1;
    klog.info("CMD: Created window instance {}", .{idx});
    
    return idx;
}

/// Destroy a CMD window by instance index
pub fn destroyCmdWindow(idx: usize) void {
    if (idx >= cmd_instance_count) return;
    
    const inst = &cmd_instances[idx];
    inst.visible = false;
    inst.focused = false;
    
    // Shift instances
    var i: usize = idx;
    while (i < cmd_instance_count - 1) : (i += 1) {
        cmd_instances[i] = cmd_instances[i + 1];
    }
    
    // Clear last slot
    cmd_instances[cmd_instance_count - 1] = .{
        .shell = undefined,
        .x = 100,
        .y = 100,
        .width = 700,
        .height = 450,
        .visible = false,
        .focused = false,
    };
    
    cmd_instance_count -= 1;
    
    // Update focus
    if (focused_cmd_index) |old_idx| {
        if (old_idx == idx) {
            if (cmd_instance_count > 0) {
                focused_cmd_index = if (idx >= cmd_instance_count) idx - 1 else idx;
                cmd_instances[focused_cmd_index.?].focused = true;
            } else {
                focused_cmd_index = null;
            }
        } else if (old_idx > idx) {
            focused_cmd_index = old_idx - 1;
        }
    }
    
    klog.info("CMD: Destroyed window instance {}", .{idx});
}

/// Close CMD window by position (for hit testing)
pub fn closeCmdWindowAtPosition(x: i32, y: i32) bool {
    for (0..cmd_instance_count) |i| {
        if (!cmd_instances[i].visible) continue;
        if (cmd_instances[i].state == .minimized) continue;
        
        const inst = &cmd_instances[i];
        if (x >= inst.x and x < inst.x + inst.width and
            y >= inst.y and y < inst.y + inst.caption_height)
        {
            // Check if close button is clicked
            const btn_h: i32 = 18;
            const btn_w_close: i32 = 48;
            const close_x = inst.x + inst.width - btn_w_close;
            const btn_y = inst.y + @divTrunc(inst.caption_height - btn_h, 2);
            
            if (x >= close_x and x < inst.x + inst.width and
                y >= btn_y and y < btn_y + btn_h)
            {
                destroyCmdWindow(i);
                return true;
            }
        }
    }
    return false;
}

/// Check if point hits a CMD window caption close button
pub fn hitTestCmdCloseButton(x: i32, y: i32) ?usize {
    for (0..cmd_instance_count) |i| {
        if (!cmd_instances[i].visible) continue;
        if (cmd_instances[i].state == .minimized) continue;
        
        const inst = &cmd_instances[i];
        if (x >= inst.x and x < inst.x + inst.width and
            y >= inst.y and y < inst.y + inst.caption_height)
        {
            const btn_h: i32 = 18;
            const btn_w_close: i32 = 48;
            const close_x = inst.x + inst.width - btn_w_close;
            const btn_y = inst.y + @divTrunc(inst.caption_height - btn_h, 2);
            
            if (x >= close_x and x < inst.x + inst.width and
                y >= btn_y and y < btn_y + btn_h)
            {
                return i;
            }
        }
    }
    return null;
}

/// Check if point hits a CMD window caption area
pub fn hitTestCmdCaption(x: i32, y: i32) ?usize {
    for (0..cmd_instance_count) |i| {
        if (!cmd_instances[i].visible) continue;
        if (cmd_instances[i].state == .minimized) continue;
        
        const inst = &cmd_instances[i];
        if (x >= inst.x and x < inst.x + inst.width and
            y >= inst.y and y < inst.y + inst.caption_height)
        {
            return i;
        }
    }
    return null;
}

/// Check if point hits a CMD window
pub fn hitTestCmdWindow(x: i32, y: i32) ?usize {
    for (0..cmd_instance_count) |i| {
        if (!cmd_instances[i].visible) continue;
        if (cmd_instances[i].state == .minimized) continue;
        
        const inst = &cmd_instances[i];
        if (x >= inst.x and x < inst.x + inst.width and
            y >= inst.y and y < inst.y + inst.height)
        {
            return i;
        }
    }
    return null;
}

/// Get the instance index for a position
pub fn getCmdInstanceAtPosition(x: i32, y: i32) ?usize {
    // Search from top (last created) to bottom
    var i: isize = @as(isize, @intCast(cmd_instance_count)) - 1;
    while (i >= 0) : (i -= 1) {
        const idx = @as(usize, @intCast(i));
        if (!cmd_instances[idx].visible) continue;
        if (cmd_instances[idx].state == .minimized) continue;
        
        const inst = &cmd_instances[idx];
        if (x >= inst.x and x < inst.x + inst.width and
            y >= inst.y and y < inst.y + inst.height)
        {
            return idx;
        }
    }
    return null;
}

/// Get focused CMD instance index
pub fn getFocusedCmdIndex() ?usize {
    return focused_cmd_index;
}

/// Set focus to a CMD instance
pub fn setFocusedCmdIndex(idx: usize) void {
    if (idx >= cmd_instance_count) return;
    
    if (focused_cmd_index) |old_idx| {
        cmd_instances[old_idx].focused = false;
    }
    
    cmd_instances[idx].focused = true;
    focused_cmd_index = idx;
}

/// Focus CMD window at position
pub fn focusCmdWindowAtPosition(x: i32, y: i32) void {
    if (getCmdInstanceAtPosition(x, y)) |idx| {
        // Bring to front (simple: just update focus)
        if (focused_cmd_index != idx) {
            if (focused_cmd_index) |old_idx| {
                cmd_instances[old_idx].focused = false;
            }
            cmd_instances[idx].focused = true;
            focused_cmd_index = idx;
        }
    }
}

/// Minimize CMD window
pub fn minimizeCmdWindow(idx: usize) void {
    if (idx >= cmd_instance_count) return;
    
    const inst = &cmd_instances[idx];
    if (inst.state == .minimized) return;
    
    inst.prev_state = inst.state;
    if (inst.state == .normal) {
        inst.prev_x = inst.x;
        inst.prev_y = inst.y;
        inst.prev_w = inst.width;
        inst.prev_h = inst.height;
    }
    
    inst.state = .minimized;
    klog.info("CMD: Minimized instance {}", .{idx});
}

/// Maximize/Restore CMD window
pub fn maximizeCmdWindow(idx: usize) void {
    if (idx >= cmd_instance_count) return;
    
    const inst = &cmd_instances[idx];
    if (inst.state == .maximized) {
        // Restore
        inst.state = inst.prev_state;
        inst.x = inst.prev_x;
        inst.y = inst.prev_y;
        inst.width = inst.prev_w;
        inst.height = inst.prev_h;
        inst.shell.x = inst.x;
        inst.shell.y = inst.y;
        inst.shell.width = inst.width;
        inst.shell.height = inst.height;
    } else {
        // Save current and maximize
        inst.prev_state = inst.state;
        if (inst.state == .normal) {
            inst.prev_x = inst.x;
            inst.prev_y = inst.y;
            inst.prev_w = inst.width;
            inst.prev_h = inst.height;
        }
        
        inst.state = .maximized;
        inst.x = 0;
        inst.y = 0;
        inst.width = 800;
        inst.height = 600;
        
        inst.shell.x = inst.x;
        inst.shell.y = inst.y;
        inst.shell.width = inst.width;
        inst.shell.height = inst.height;
    }
    
    klog.info("CMD: Toggle maximize instance {}, state={}", .{idx, @tagName(inst.state)});
}

/// Restore CMD window from minimized state
pub fn restoreCmdWindow(idx: usize) void {
    if (idx >= cmd_instance_count) return;
    
    const inst = &cmd_instances[idx];
    if (inst.state != .minimized) return;
    
    inst.state = inst.prev_state;
    klog.info("CMD: Restored instance {}", .{idx});
}

/// Handle caption button hover
pub fn updateCmdCaptionHover(x: i32, y: i32) void {
    for (0..cmd_instance_count) |i| {
        cmd_instances[i].caption_hover = .none;
    }
    
    if (hitTestCmdCaption(x, y)) |idx| {
        const inst = &cmd_instances[idx];
        const btn_h: i32 = 18;
        const btn_w: i32 = 40;
        const btn_w_close: i32 = 48;
        const btn_y = inst.y + @divTrunc(inst.caption_height - btn_h, 2);
        
        // Check minimize button
        const min_x = inst.x + inst.width - btn_w_close - btn_w * 2 - 4;
        if (x >= min_x and x < min_x + btn_w and y >= btn_y and y < btn_y + btn_h) {
            cmd_instances[idx].caption_hover = .minimize;
            return;
        }
        
        // Check maximize button
        const max_x = inst.x + inst.width - btn_w_close - btn_w - 2;
        if (x >= max_x and x < max_x + btn_w and y >= btn_y and y < btn_y + btn_h) {
            cmd_instances[idx].caption_hover = .maximize;
            return;
        }
        
        // Check close button
        const close_x = inst.x + inst.width - btn_w_close;
        if (x >= close_x and x < inst.x + inst.width and y >= btn_y and y < btn_y + btn_h) {
            cmd_instances[idx].caption_hover = .close;
            return;
        }
    }
}

/// Handle CMD window caption click
pub fn handleCaptionClick(idx: usize) CaptionButtonType {
    if (idx >= cmd_instance_count) return .none;
    return cmd_instances[idx].caption_hover;
}

/// Move CMD window
pub fn moveCmdWindow(idx: usize, x: i32, y: i32) void {
    if (idx >= cmd_instance_count) return;
    
    const inst = &cmd_instances[idx];
    inst.x = x;
    inst.y = y;
    inst.shell.x = x;
    inst.shell.y = y;
}

/// Resize CMD window
pub fn resizeCmdWindow(idx: usize, width: i32, height: i32) void {
    if (idx >= cmd_instance_count) return;
    
    const inst = &cmd_instances[idx];
    inst.width = width;
    inst.height = height;
    inst.shell.width = width;
    inst.shell.height = height;
}

/// Start CMD window drag
var cmd_drag_index: ?usize = null;
var cmd_drag_off_x: i32 = 0;
var cmd_drag_off_y: i32 = 0;

pub fn startCmdWindowDrag(idx: usize, x: i32, y: i32) void {
    if (idx >= cmd_instance_count) return;
    
    const inst = &cmd_instances[idx];
    cmd_drag_index = idx;
    cmd_drag_off_x = x - inst.x;
    cmd_drag_off_y = y - inst.y;
    
    // If maximized, restore first
    if (inst.state == .maximized) {
        maximizeCmdWindow(idx);
        // Adjust drag offset after restore
        cmd_drag_off_x = x - inst.x;
        cmd_drag_off_y = y - inst.y;
    }
}

/// Process CMD window drag
pub fn processCmdWindowDrag(x: i32, y: i32) void {
    if (cmd_drag_index) |idx| {
        moveCmdWindow(idx, x - cmd_drag_off_x, y - cmd_drag_off_y);
    }
}

/// End CMD window drag
pub fn endCmdWindowDrag() void {
    cmd_drag_index = null;
}

/// Check if CMD window is being dragged
pub fn isCmdWindowDragging() bool {
    return cmd_drag_index != null;
}

/// Get dragging CMD window index
pub fn getCmdDragIndex() ?usize {
    return cmd_drag_index;
}

/// Add character input to focused CMD
pub fn cmdAppendChar(ch: u8) void {
    if (focused_cmd_index) |idx| {
        cmd_instances[idx].shell.appendChar(ch);
    }
}

/// Backspace in focused CMD
pub fn cmdBackspace() void {
    if (focused_cmd_index) |idx| {
        cmd_instances[idx].shell.backspace();
    }
}

/// Clear input in focused CMD
pub fn cmdClearInput() void {
    if (focused_cmd_index) |idx| {
        cmd_instances[idx].shell.clearInput();
    }
}

/// Execute command in focused CMD
pub fn cmdExecuteCommand() void {
    if (focused_cmd_index) |idx| {
        const inst = &cmd_instances[idx];
        const input = inst.shell.input_buffer[0..inst.shell.input_len];
        inst.shell.executeCommand(input);
        inst.shell.clearInput();
    }
}

/// Update cursor blink for all CMD instances
pub fn updateAllCmdCursors() void {
    for (0..cmd_instance_count) |i| {
        cmd_instances[i].shell.updateCursor();
    }
}

/// Get the number of CMD instances
pub fn getCmdInstanceCount() usize {
    return cmd_instance_count;
}

/// Get CMD instance by index
pub fn getCmdInstance(idx: usize) ?*CmdWindowInstance {
    if (idx >= cmd_instance_count) return null;
    return &cmd_instances[idx];
}

/// Check if any CMD window is visible
pub fn anyCmdWindowVisible() bool {
    for (0..cmd_instance_count) |i| {
        if (cmd_instances[i].visible) return true;
    }
    return false;
}

/// Render all CMD windows (kernel framebuffer path)
pub fn renderAllCmdInstances(t: *const theme.ThemeColors) void {
    for (0..cmd_instance_count) |i| {
        const inst = &cmd_instances[i];
        if (!inst.visible) continue;
        if (inst.state == .minimized) continue;
        
        drawCmdWindowFrame(inst, t);
        drawCmdContent(inst);
    }
}

/// Draw window frame for CMD
fn drawCmdWindowFrame(inst: *const CmdWindowInstance, t: *const theme.ThemeColors) void {
    const wx = inst.x;
    const wy = inst.y;
    const ww = inst.width;
    const wh = inst.height;
    const ch = inst.caption_height;
    
    // Draw window background (black for CMD)
    fb.fillRect(wx, wy + ch, ww, wh - ch, rgb(0x00, 0x00, 0x00));
    
    // Draw border
    fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    
    // Draw caption background
    const caption_bg = if (inst.focused) rgb(0x00, 0x3C, 0x80) else rgb(0x80, 0x80, 0x80);
    fb.fillRect(wx + 1, wy + 1, ww - 2, ch - 1, caption_bg);
    
    // Draw title text
    const title = "Administrator: C:\\Windows\\system32\\cmd.exe";
    fb.drawTextTransparent(wx + 8, wy + @divTrunc(ch - 14, 2), title, rgb(0xFF, 0xFF, 0xFF));
    
    // Draw caption buttons
    const btn_h: i32 = 18;
    const btn_y = wy + @divTrunc(ch - btn_h, 2);
    const btn_w: i32 = 40;
    const btn_w_close: i32 = 48;
    
    // Minimize button
    const min_x = wx + ww - btn_w_close - btn_w * 2 - 4;
    if (inst.caption_hover == .minimize) {
        fb.blendTintRect(min_x, btn_y, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
    }
    fb.drawHLine(min_x, btn_y, btn_w, rgb(0x40, 0x50, 0x60));
    fb.drawHLine(min_x, btn_y + btn_h - 1, btn_w, rgb(0x40, 0x50, 0x60));
    fb.drawVLine(min_x, btn_y, btn_h, rgb(0x40, 0x50, 0x60));
    fb.drawVLine(min_x + btn_w - 1, btn_y, btn_h, rgb(0x40, 0x50, 0x60));
    // Minimize glyph (underscore)
    fb.fillRect(min_x + btn_w / 2 - 4, btn_y + btn_h / 2 + 1, 8, 2, rgb(0xE8, 0xF2, 0xFA));
    
    // Maximize button
    const max_x = wx + ww - btn_w_close - btn_w - 2;
    if (inst.caption_hover == .maximize) {
        fb.blendTintRect(max_x, btn_y, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
    }
    fb.drawHLine(max_x, btn_y, btn_w, rgb(0x40, 0x50, 0x60));
    fb.drawHLine(max_x, btn_y + btn_h - 1, btn_w, rgb(0x40, 0x50, 0x60));
    fb.drawVLine(max_x, btn_y, btn_h, rgb(0x40, 0x50, 0x60));
    fb.drawVLine(max_x + btn_w - 1, btn_y, btn_h, rgb(0x40, 0x50, 0x60));
    // Maximize glyph (square)
    fb.drawRect(max_x + btn_w / 2 - 4, btn_y + btn_h / 2 - 4, 8, 8, rgb(0xE8, 0xF2, 0xFA));
    
    // Close button
    const close_x = wx + ww - btn_w_close;
    if (inst.caption_hover == .close) {
        fb.fillRect(close_x, btn_y, btn_w_close, btn_h, rgb(0xE8, 0x11, 0x23));
    }
    fb.drawHLine(close_x, btn_y, btn_w_close, rgb(0x40, 0x50, 0x60));
    fb.drawHLine(close_x, btn_y + btn_h - 1, btn_w_close, rgb(0x40, 0x50, 0x60));
    fb.drawVLine(close_x, btn_y, btn_h, rgb(0x40, 0x50, 0x60));
    fb.drawVLine(close_x + btn_w_close - 1, btn_y, btn_h, rgb(0x40, 0x50, 0x60));
    // Close glyph (X)
    const cx = close_x + btn_w_close / 2;
    const cy = btn_y + btn_h / 2;
    const close_color = if (inst.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA);
    var d: i32 = -4;
    while (d <= 4) : (d += 1) {
        fb.putPixel32(@intCast(cx + d), @intCast(cy + d), close_color);
        fb.putPixel32(@intCast(cx + d), @intCast(cy - d), close_color);
    }
    
    _ = t;
}

/// Draw CMD content
fn drawCmdContent(inst: *const CmdWindowInstance) void {
    const line_height: i32 = 16;
    const start_y = inst.y + inst.caption_height + 4;
    const content_x = inst.x + 8;
    const content_bottom = inst.y + inst.height - 30;
    
    // Draw history lines
    var y_offset: i32 = start_y;
    var line_idx: usize = if (inst.shell.scroll_offset > 0) @as(usize, @intCast(inst.shell.scroll_offset)) else 0;
    
    while (line_idx < inst.shell.line_count and y_offset < content_bottom) {
        const cmdline = inst.shell.lines[line_idx];
        
        // Draw output (before prompt/command for cmd style)
        if (cmdline.output.len > 0) {
            const max_chars = @divTrunc(inst.width - 16, 8);
            var out_idx: usize = 0;
            while (out_idx < cmdline.output.len and y_offset < content_bottom) {
                var line_end = out_idx;
                var chars: usize = 0;
                while (line_end < cmdline.output.len and chars < @as(usize, @intCast(max_chars))) {
                    if (cmdline.output[line_end] == '\n' or cmdline.output[line_end] == '\r') {
                        line_end += 1;
                        if (line_end < cmdline.output.len and cmdline.output[line_end] == '\n') {
                            line_end += 1;
                        }
                        break;
                    }
                    line_end += 1;
                    chars += 1;
                }
                fb.drawTextTransparent(content_x, y_offset, cmdline.output[out_idx..line_end], rgb(0xCC, 0xCC, 0xCC));
                y_offset += line_height;
                out_idx = line_end;
            }
        }
        
        // Draw prompt
        if (cmdline.prompt.len > 0) {
            fb.drawTextTransparent(content_x, y_offset, cmdline.prompt, rgb(0xFF, 0xFF, 0xFF));
        }
        
        // Draw command
        if (cmdline.command.len > 0) {
            fb.drawTextTransparent(content_x + @as(i32, @intCast(cmdline.prompt.len * 8)), y_offset, cmdline.command, rgb(0xFF, 0xFF, 0xFF));
        }
        
        y_offset += line_height;
        line_idx += 1;
    }
    
    // Draw current prompt line
    const prompt = inst.shell.getPrompt();
    const prompt_y = inst.y + inst.height - 24;
    fb.drawTextTransparent(content_x, prompt_y, prompt, rgb(0xCC, 0xCC, 0xCC));
    
    // Draw input
    if (inst.shell.input_len > 0) {
        const input_x = content_x + @as(i32, @intCast(prompt.len * 8));
        fb.drawTextTransparent(input_x, prompt_y, inst.shell.input_buffer[0..inst.shell.input_len], rgb(0xFF, 0xFF, 0xFF));
    }
    
    // Draw cursor
    if (inst.focused and inst.shell.cursor_blink) {
        const input_x = content_x + @as(i32, @intCast(prompt.len * 8)) + inst.shell.cursor_x * 8;
        fb.drawVLine(input_x, prompt_y, 14, rgb(0xFF, 0xFF, 0xFF));
    }
}
