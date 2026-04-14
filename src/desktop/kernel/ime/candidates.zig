// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/kernel/ime/candidates.zig
// Purpose: Candidate Window - displays input method candidates
//
// Clean-room implementation. Reference: Microsoft IMM32 Candidate List behavior.

const std = @import("std");
const klog = @import("../../../rtl/klog.zig");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");

/// Maximum candidates to display
pub const MAX_CANDIDATES: usize = 9;

/// Maximum candidate string length
pub const MAX_CANDIDATE_LEN: usize = 32;

/// Candidate window
pub const CandidateWindow = struct {
    /// Candidate list
    candidates: [MAX_CANDIDATES][MAX_CANDIDATE_LEN]u8,
    count: usize,

    /// Currently selected candidate index
    selected: usize,

    /// Window position
    x: i32,
    y: i32,

    /// Window dimensions
    width: i32,
    height: i32,

    /// Visibility
    visible: bool,

    /// Hover state for mouse interaction
    hover_idx: usize,

    /// Initialize candidate window
    pub fn create(x_pos: i32, y_pos: i32) CandidateWindow {
        return .{
            .candidates = [_][MAX_CANDIDATE_LEN]u8{[_]u8{0} ** MAX_CANDIDATE_LEN} ** MAX_CANDIDATES,
            .count = 0,
            .selected = 0,
            .x = x_pos,
            .y = y_pos,
            .width = 180,
            .height = @as(i32, @intCast(MAX_CANDIDATES)) * 20 + 8,
            .visible = false,
            .hover_idx = MAX_CANDIDATES,
        };
    }

    /// Update position
    pub fn updatePosition(w: *CandidateWindow, x: i32, y: i32) void {
        w.x = x;
        w.y = y;
    }

    /// Set candidates
    pub fn setCandidates(w: *CandidateWindow, list: []const [MAX_CANDIDATE_LEN]u8, cnt: usize) void {
        w.count = @min(cnt, MAX_CANDIDATES);
        for (0..w.count) |i| {
            @memcpy(w.candidates[i][0..list[i].len], list[i][0..list[i].len]);
            // Null terminate
            if (list[i].len < MAX_CANDIDATE_LEN) {
                w.candidates[i][list[i].len] = 0;
            }
        }
        w.selected = 0;
        w.visible = w.count > 0;
    }

    /// Clear candidates
    pub fn clear(w: *CandidateWindow) void {
        w.count = 0;
        w.selected = 0;
        w.visible = false;
        w.hover_idx = MAX_CANDIDATES;
    }

    /// Get candidate by index
    pub fn getCandidate(w: *const CandidateWindow, idx: usize) []const u8 {
        if (idx >= w.count) return "";
        const len = std.mem.indexOfScalar(u8, &w.candidates[idx], 0) orelse MAX_CANDIDATE_LEN;
        return w.candidates[idx][0..len];
    }

    /// Get selected candidate
    pub fn getSelected(w: *const CandidateWindow) []const u8 {
        return w.getCandidate(w.selected);
    }

    /// Select candidate by index
    pub fn select(w: *CandidateWindow, idx: usize) void {
        if (idx < w.count) {
            w.selected = idx;
            klog.info("ime: selected candidate {}: {s}", .{ idx, w.getCandidate(idx) });
        }
    }

    /// Select next candidate
    pub fn selectNext(w: *CandidateWindow) void {
        if (w.count > 0) {
            w.selected = (w.selected + 1) % w.count;
        }
    }

    /// Select previous candidate
    pub fn selectPrev(w: *CandidateWindow) void {
        if (w.count > 0) {
            if (w.selected == 0) {
                w.selected = w.count - 1;
            } else {
                w.selected -= 1;
            }
        }
    }

    /// Handle mouse hover
    pub fn handleMouseMove(w: *CandidateWindow, mx: i32, my: i32) void {
        if (!w.visible) return;
        if (mx >= w.x and mx < w.x + w.width and my >= w.y and my < w.y + w.height) {
            const row = (my - w.y - 4) / 20;
            if (row >= 0 and @as(usize, @intCast(row)) < w.count) {
                w.hover_idx = @as(usize, @intCast(row));
                return;
            }
        }
        w.hover_idx = MAX_CANDIDATES;
    }

    /// Handle mouse click
    pub fn handleClick(w: *CandidateWindow, mx: i32, my: i32) bool {
        if (!w.visible) return false;
        if (mx >= w.x and mx < w.x + w.width and my >= w.y and my < w.y + w.height) {
            const row = (my - w.y - 4) / 20;
            if (row >= 0 and @as(usize, @intCast(row)) < w.count) {
                w.select(@as(usize, @intCast(row)));
                return true;
            }
        }
        return false;
    }

    /// Render candidate window
    pub fn render(w: *CandidateWindow, base_x: i32, base_y: i32) void {
        if (!w.visible or w.count == 0) return;

        const x = base_x;
        const y = base_y + 24; // Below the text being composed

        // Draw background
        fb.fillRect(x, y, w.width, w.height, theme.rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(x, y, w.width, w.height, theme.rgb(0xFF, 0xFF, 0xFF), theme.rgb(0xA0, 0xA0, 0xA0));

        // Draw each candidate
        var cy: i32 = y + 6;
        const row_height: i32 = 20;

        for (0..w.count) |i| {
            const candidate = w.getCandidate(i);

            // Highlight selected
            if (i == w.selected) {
                fb.fillRect(x + 2, cy, w.width - 4, row_height - 1, theme.rgb(0xD0, 0xE0, 0xF0));
            } else if (i == w.hover_idx) {
                fb.fillRect(x + 2, cy, w.width - 4, row_height - 1, theme.rgb(0xE8, 0xE8, 0xE8));
            }

            // Draw number prefix
            const num_str: []const u8 = if (i < 9) &.{ '1' + @as(u8, @intCast(i)) } else "10+";
            fb.drawTextTransparent(x + 4, cy + 4, num_str, theme.rgb(0x40, 0x40, 0x40));

            // Draw candidate text
            fb.drawTextTransparent(x + 24, cy + 4, candidate, theme.rgb(0x20, 0x20, 0x20));

            cy += row_height;
        }
    }
};
