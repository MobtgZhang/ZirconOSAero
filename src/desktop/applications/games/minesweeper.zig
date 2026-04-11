// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/games/minesweeper.zig
// Purpose: Minesweeper game implementation
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const klog = @import("../../../rtl/klog.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const Difficulty = enum { beginner, intermediate, expert };
pub const CellState = enum { hidden, revealed, flagged };
pub const CellValue = enum(u4) { mine = 9, _ };

pub const Cell = struct {
    state: CellState,
    value: u4,
    is_mine: bool,
};

pub const MinesweeperGame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,

    cells: []Cell,
    grid_width: u32,
    grid_height: u32,
    mine_count: u32,
    flag_count: u32,
    revealed_count: u32,
    difficulty: Difficulty,
    game_state: GameState,
    start_time: u32,
    elapsed_time: u32,
    first_click: bool,
    smiley_state: SmileyState,
    caption_hover: CaptionButtonType,

    const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const GameState = enum { waiting, playing, won, lost };

    pub const SmileyState = enum { normal, worried, dead, cool };

    pub fn create(x_pos: i32, y_pos: i32, diff: Difficulty) MinesweeperGame {
        var w: u32 = 9;
        var h: u32 = 9;
        var mines: u32 = 10;
        switch (diff) {
            .beginner => { w = 9; h = 9; mines = 10; },
            .intermediate => { w = 16; h = 16; mines = 40; },
            .expert => { w = 30; h = 16; mines = 99; },
        }
        const cell_count = w * h;
        var cells: [900]Cell = undefined;
        for (&cells, 0..) |*c, i| {
            c.* = .{ .state = .hidden, .value = 0, .is_mine = false };
            if (i < mines) c.is_mine = true;
        }
        return .{
            .x = x_pos, .y = y_pos,
            .width = @as(i32, @intCast(w)) * 20 + 20,
            .height = @as(i32, @intCast(h)) * 20 + 60,
            .visible = true,
            .cells = cells[0..cell_count],
            .grid_width = w,
            .grid_height = h,
            .mine_count = mines,
            .flag_count = 0,
            .revealed_count = 0,
            .difficulty = diff,
            .game_state = .waiting,
            .start_time = 0,
            .elapsed_time = 0,
            .first_click = true,
            .smiley_state = .normal,
            .caption_hover = .none,
        };
    }

    pub fn reset(ms: *MinesweeperGame) void {
        var w: u32 = 9;
        var h: u32 = 9;
        var mines: u32 = 10;
        switch (ms.difficulty) {
            .beginner => { w = 9; h = 9; mines = 10; },
            .intermediate => { w = 16; h = 16; mines = 40; },
            .expert => { w = 30; h = 16; mines = 99; },
        }
        ms.grid_width = w;
        ms.grid_height = h;
        ms.mine_count = mines;
        ms.flag_count = 0;
        ms.revealed_count = 0;
        ms.game_state = .waiting;
        ms.start_time = 0;
        ms.elapsed_time = 0;
        ms.first_click = true;
        ms.smiley_state = .normal;

        var i: usize = 0;
        while (i < ms.cells.len) : (i += 1) {
            ms.cells[i].state = .hidden;
            ms.cells[i].value = 0;
            ms.cells[i].is_mine = (i < mines);
        }
    }

    pub fn placeMines(ms: *MinesweeperGame, first_x: u32, first_y: u32) void {
        var seed: u32 = @truncate(@as(u64, @intFromPtr(ms)) +% @as(u64, ms.elapsed_time));
        var placed: u32 = 0;
        while (placed < ms.mine_count) {
            const rx = seed % ms.grid_width;
            const ry = (seed / ms.grid_width) % ms.grid_height;
            const idx = ry * ms.grid_width + rx;
            if (!ms.cells[idx].is_mine and rx != first_x and ry != first_y) {
                ms.cells[idx].is_mine = true;
                placed += 1;
            }
            seed = seed *% 1664525 +% 1013904223;
        }
        for (ms.cells, 0..) |*c, i| {
            if (c.is_mine) continue;
            var count: u4 = 0;
            const gx = @as(u32, @intCast(i % ms.grid_width));
            const gy = @as(u32, @intCast(i / ms.grid_width));
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    if (dx == 0 and dy == 0) continue;
                    const nx: i32 = @as(i32, @intCast(gx)) + dx;
                    const ny: i32 = @as(i32, @intCast(gy)) + dy;
                    if (nx >= 0 and nx < ms.grid_width and ny >= 0 and ny < ms.grid_height) {
                        const nidx = @as(usize, @intCast(ny)) * ms.grid_width + @as(usize, @intCast(nx));
                        if (ms.cells[nidx].is_mine) count += 1;
                    }
                }
            }
            c.value = count;
        }
    }

    pub fn revealCell(ms: *MinesweeperGame, gx: u32, gy: u32) void {
        if (gx >= ms.grid_width or gy >= ms.grid_height) return;
        const idx = gy * ms.grid_width + gx;
        var cell = &ms.cells[idx];
        if (cell.state == .revealed or cell.state == .flagged) return;

        if (ms.first_click) {
            ms.first_click = false;
            ms.placeMines(gx, gy);
            ms.game_state = .playing;
        }

        cell.state = .revealed;
        ms.revealed_count += 1;

        if (cell.is_mine) {
            ms.game_state = .lost;
            ms.smiley_state = .dead;
            return;
        }

        if (cell.value == 0) {
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    if (dx == 0 and dy == 0) continue;
                    const nx: i32 = @as(i32, @intCast(gx)) + dx;
                    const ny: i32 = @as(i32, @intCast(gy)) + dy;
                    if (nx >= 0 and nx < ms.grid_width and ny >= 0 and ny < ms.grid_height) {
                        ms.revealCell(@intCast(nx), @intCast(ny));
                    }
                }
            }
        }

        const total_safe = ms.grid_width * ms.grid_height - ms.mine_count;
        if (ms.revealed_count >= total_safe) {
            ms.game_state = .won;
            ms.smiley_state = .cool;
        }
    }

    pub fn toggleFlag(ms: *MinesweeperGame, gx: u32, gy: u32) void {
        if (gx >= ms.grid_width or gy >= ms.grid_height) return;
        const idx = gy * ms.grid_width + gx;
        var cell = &ms.cells[idx];
        if (cell.state == .revealed) return;

        if (cell.state == .flagged) {
            cell.state = .hidden;
            ms.flag_count -= 1;
        } else {
            cell.state = .flagged;
            ms.flag_count += 1;
        }
    }

    pub fn render(ms: *MinesweeperGame, t: *const theme_mod.ThemeColors) void {
        if (!ms.visible) return;
        ms.renderHeader(t);
        ms.renderGrid(t);
    }

    fn renderHeader(ms: *MinesweeperGame, _: *const theme_mod.ThemeColors) void {
        const hx = ms.x;
        const hy = ms.y;
        const hw = ms.width;

        fb.fillRect(hx, hy, hw, 30, rgb(0xC0, 0xC0, 0xC0));
        fb.draw3DRect(hx, hy, hw, 30, rgb(0xFF, 0xFF, 0xFF), rgb(0x60, 0x60, 0x60));

        const mine_display = @as(i32, @intCast(ms.mine_count)) - @as(i32, @intCast(ms.flag_count));
        var mine_buf: [8]u8 = undefined;
        const mine_text = std.fmt.bufPrint(&mine_buf, "{d: >3}", .{@as(i32, @intCast(@max(0, mine_display)))}) catch "  0";
        fb.drawTextTransparent(hx + 8, hy + 8, mine_text, rgb(0xFF, 0x00, 0x00));

        const smiley_x = hx + @divTrunc(hw - 24, 2);
        fb.fillRect(smiley_x, hy + 3, 24, 24, rgb(0xFF, 0xFF, 0x00));
        fb.draw3DRect(smiley_x, hy + 3, 24, 24, rgb(0xFF, 0xFF, 0x00), rgb(0xC0, 0xC0, 0x00));
        fb.fillRect(smiley_x + 5, hy + 9, 5, 5, rgb(0x00, 0x00, 0x00));
        fb.fillRect(smiley_x + 14, hy + 9, 5, 5, rgb(0x00, 0x00, 0x00));
        const smile_y = switch (ms.smiley_state) {
            .normal, .cool => hy + 16,
            .worried => hy + 17,
            .dead => hy + 18,
        };
        fb.fillRect(smiley_x + 4, smile_y, 16, 3, rgb(0x00, 0x00, 0x00));

        var time_buf: [8]u8 = undefined;
        const time_text = std.fmt.bufPrint(&time_buf, "{d: >3}", .{@as(i32, @intCast(@min(999, ms.elapsed_time)))}) catch "  0";
        fb.drawTextTransparent(hx + hw - 40, hy + 8, time_text, rgb(0xFF, 0x00, 0x00));
    }

    fn renderGrid(ms: *MinesweeperGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const gx = ms.x;
        const gy = ms.y + 30;
        const cell_size: i32 = 20;

        fb.fillRect(gx, gy, ms.width, @as(i32, @intCast(ms.grid_height)) * cell_size, rgb(0xC0, 0xC0, 0xC0));
        fb.draw3DRect(gx, gy, ms.width, @as(i32, @intCast(ms.grid_height)) * cell_size, rgb(0xFF, 0xFF, 0xFF), rgb(0x60, 0x60, 0x60));

        for (ms.cells, 0..) |*cell, i| {
            const cx = gx + @as(i32, @intCast(i % ms.grid_width)) * cell_size;
            const cy = gy + @as(i32, @intCast(i / ms.grid_width)) * cell_size;

            switch (cell.state) {
                .hidden => {
                    fb.fillRect(cx + 1, cy + 1, cell_size - 2, cell_size - 2, rgb(0xC0, 0xC0, 0xC0));
                    fb.drawHLine(cx + 1, cy + 1, cell_size - 2, rgb(0xFF, 0xFF, 0xFF));
                    fb.drawVLine(cx + 1, cy + 1, cell_size - 2, rgb(0xFF, 0xFF, 0xFF));
                    fb.drawHLine(cx + 1, cy + cell_size - 1, cell_size - 2, rgb(0x60, 0x60, 0x60));
                    fb.drawVLine(cx + cell_size - 1, cy + 1, cell_size - 2, rgb(0x60, 0x60, 0x60));
                },
                .flagged => {
                    fb.fillRect(cx + 1, cy + 1, cell_size - 2, cell_size - 2, rgb(0xC0, 0xC0, 0xC0));
                    fb.drawTextTransparent(cx + 6, cy + 4, "F", rgb(0xFF, 0x00, 0x00));
                },
                .revealed => {
                    fb.fillRect(cx, cy, cell_size, cell_size, rgb(0xD8, 0xDC, 0xE4));
                    if (cell.is_mine) {
                        fb.fillRect(cx + 4, cy + 4, cell_size - 8, cell_size - 8, rgb(0x00, 0x00, 0x00));
                    } else if (cell.value > 0) {
                        const color = switch (cell.value) {
                            1 => rgb(0x00, 0x00, 0xFF),
                            2 => rgb(0x00, 0x80, 0x00),
                            3 => rgb(0xFF, 0x00, 0x00),
                            4 => rgb(0x00, 0x00, 0x80),
                            5 => rgb(0x80, 0x00, 0x00),
                            6 => rgb(0x00, 0x80, 0x80),
                            7 => rgb(0x00, 0x00, 0x00),
                            8 => rgb(0x80, 0x80, 0x80),
                            else => rgb(0x00, 0x00, 0x00),
                        };
                        var buf: [2]u8 = undefined;
                        const text = std.fmt.bufPrint(&buf, "{d}", .{cell.value}) catch " ";
                        fb.drawTextTransparent(cx + 6, cy + 4, text, color);
                    }
                },
            }
        }
    }
};
