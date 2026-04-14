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
// Module: src/desktop/applications/games/purble_place.zig
// Purpose: Purble Place - Children's game suite (3 mini-games)
// 
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

/// Game types in Purble Place
pub const MiniGame = enum {
    purble_shop,    // Match items to customer orders
    rubber_duck,    // Find the duck among duplicates
    grid_pattern,   // Complete the pattern
};

/// Purble Shop item types
pub const ShopItem = enum {
    hat,
    glasses,
    bow_tie,
    flower,
};

/// Customer order
pub const CustomerOrder = struct {
    hat: bool,
    glasses: bool,
    bow_tie: bool,
    flower: bool,
};

/// Purble Place main window
pub const PurblePlaceGame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    
    current_game: MiniGame,
    score: u32,
    level: u8,
    game_over: bool,
    show_menu: bool,
    
    // Purble Shop state
    customer_order: CustomerOrder,
    selected_items: [4]bool,
    customer_x: i32,
    
    // Rubber Duck state
    duck_position: u8,
    guess_count: u8,
    max_guesses: u8,
    
    // Grid Pattern state
    pattern: [16]bool,
    grid_selections: [16]bool,
    pattern_size: u8,
    
    hover_new: bool,
    hover_shop: bool,
    hover_duck: bool,
    hover_grid: bool,
    hover_1: bool,
    hover_2: bool,
    hover_3: bool,
    hover_4: bool,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) PurblePlaceGame {
        return .{
            .x = x_pos, .y = y_pos,
            .width = 560, .height = 420,
            .visible = true, .caption_hover = .none,
            .current_game = .purble_shop,
            .score = 0, .level = 1,
            .game_over = false, .show_menu = true,
            .customer_order = .{ .hat = false, .glasses = false, .bow_tie = false, .flower = false },
            .selected_items = .{ false, false, false, false },
            .customer_x = 300,
            .duck_position = 0,
            .guess_count = 0,
            .max_guesses = 3,
            .pattern = .{ false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false },
            .grid_selections = .{ false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false },
            .pattern_size = 4,
            .hover_new = false, .hover_shop = false,
            .hover_duck = false, .hover_grid = false,
            .hover_1 = false, .hover_2 = false,
            .hover_3 = false, .hover_4 = false,
        };
    }

    pub fn newGame(pp: *PurblePlaceGame) void {
        pp.score = 0;
        pp.level = 1;
        pp.game_over = false;
        pp.show_menu = true;
        
        switch (pp.current_game) {
            .purble_shop => pp.initShopLevel(),
            .rubber_duck => pp.initDuckLevel(),
            .grid_pattern => pp.initGridLevel(),
        }
    }

    pub fn initShopLevel(pp: *PurblePlaceGame) void {
        pp.customer_order = .{
            .hat = pp.level >= 1,
            .glasses = pp.level >= 2,
            .bow_tie = pp.level >= 3,
            .flower = pp.level >= 4,
        };
        pp.selected_items = .{ false, false, false, false };
        pp.show_menu = false;
    }

    pub fn initDuckLevel(pp: *PurblePlaceGame) void {
        pp.max_guesses = @max(3, 5 - pp.level);
        pp.guess_count = 0;
        pp.duck_position = @as(u8, @intCast((pp.level * 7) % 9));
        pp.show_menu = false;
    }

    pub fn initGridLevel(pp: *PurblePlaceGame) void {
        pp.pattern_size = @min(2 + pp.level, 4);
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            pp.pattern[i] = false;
            pp.grid_selections[i] = false;
        }
        // Generate simple pattern
        i = 0;
        while (i < pp.pattern_size) : (i += 1) {
            pp.pattern[i * 4] = true;
        }
        pp.show_menu = false;
    }

    pub fn handleShopItemClick(pp: *PurblePlaceGame, item_idx: u8) void {
        if (item_idx < 4) {
            pp.selected_items[item_idx] = !pp.selected_items[item_idx];
        }
    }

    pub fn submitShopOrder(pp: *PurblePlaceGame) void {
        const correct = pp.selected_items[0] == pp.customer_order.hat and
                        pp.selected_items[1] == pp.customer_order.glasses and
                        pp.selected_items[2] == pp.customer_order.bow_tie and
                        pp.selected_items[3] == pp.customer_order.flower;
        
        if (correct) {
            pp.score += @as(u32, pp.level) * 100;
            pp.level += 1;
            pp.initShopLevel();
        } else {
            pp.level = @max(1, pp.level - 1);
            pp.initShopLevel();
        }
    }

    pub fn handleDuckClick(pp: *PurblePlaceGame, duck_idx: u8) void {
        if (pp.guess_count >= pp.max_guesses) return;
        
        pp.guess_count += 1;
        
        if (duck_idx == pp.duck_position) {
            pp.score += @as(u32, pp.max_guesses - pp.guess_count + 1) * 50;
            pp.level += 1;
            pp.initDuckLevel();
        } else if (pp.guess_count >= pp.max_guesses) {
            pp.level = @max(1, pp.level - 1);
            pp.initDuckLevel();
        }
    }

    pub fn submitGridPattern(pp: *PurblePlaceGame) void {
        var correct = true;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (pp.pattern[i] != pp.grid_selections[i]) {
                correct = false;
                break;
            }
        }
        
        if (correct) {
            pp.score += @as(u32, pp.level) * 150;
            pp.level += 1;
            pp.initGridLevel();
        } else {
            // Clear and retry
            i = 0;
            while (i < 16) : (i += 1) {
                pp.grid_selections[i] = false;
            }
        }
    }

    pub fn handleCellClick(pp: *PurblePlaceGame, cell_idx: u8) void {
        if (cell_idx < 16) {
            pp.grid_selections[cell_idx] = !pp.grid_selections[cell_idx];
        }
    }

    pub fn render(pp: *PurblePlaceGame, t: *const theme_mod.ThemeColors) void {
        if (!pp.visible) return;
        _ = t;

        const wx = pp.x;
        const wy = pp.y;
        const ww = pp.width;
        const wh = pp.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x90, 0x50, 0xD0), rgb(0xB0, 0x70, 0xE0));
        fb.drawTextTransparent(wx + 8, wy + 6, "Purble Place", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (pp.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 80, rgb(0xF8, 0xF0, 0xFF));
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE0, 0xD0, 0xF0), rgb(0x60, 0x50, 0x80));

        // Score and level
        var buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&buf, "Score: {d}", .{pp.score}) catch "";
        fb.drawTextTransparent(wx + 8, wy + 38, score_str, rgb(0x50, 0x40, 0x60));
        
        var level_buf: [16]u8 = undefined;
        const level_str = std.fmt.bufPrint(&level_buf, "Level: {d}", .{pp.level}) catch "";
        fb.drawTextTransparent(wx + ww - 80, wy + 38, level_str, rgb(0x50, 0x40, 0x60));

        if (pp.show_menu) {
            pp.renderMenu(wx, wy, ww, wh);
        } else {
            switch (pp.current_game) {
                .purble_shop => pp.renderShop(wx, wy, ww, wh),
                .rubber_duck => pp.renderDuck(wx, wy, ww, wh),
                .grid_pattern => pp.renderGrid(wx, wy, ww, wh),
            }
        }

        // Status bar
        const sy = wy + wh - 45;
        fb.fillRect(wx, sy, ww, 45, rgb(0xF0, 0xE8, 0xF8));
        fb.fillRect(wx, sy, ww, 1, rgb(0xD0, 0xC8, 0xE0));

        const game_name: []const u8 = switch (pp.current_game) {
            .purble_shop => "Purble Shop",
            .rubber_duck => "Rubber Ducks",
            .grid_pattern => "Grid Pattern",
        };
        fb.drawTextTransparent(wx + 8, sy + 8, game_name, rgb(0x40, 0x30, 0x50));
    }

    fn renderMenu(pp: *PurblePlaceGame, wx: i32, wy: i32, ww: i32, wh: i32) void {
        _ = wh;
        // Title
        fb.drawTextTransparent(wx + ww/2 - 60, wy + 60, "Choose a Game!", rgb(0x60, 0x40, 0x80));
        
        const btn_w: i32 = 140;
        const btn_h: i32 = 80;
        const spacing: i32 = 20;
        const total_w = 3 * btn_w + 2 * spacing;
        const start_x = wx + (ww - total_w) / 2;
        
        // Purble Shop button
        const shop_y = wy + 120;
        const shop_color = if (pp.hover_shop) rgb(0xC0, 0x90, 0xE0) else rgb(0xA0, 0x70, 0xD0);
        fb.fillRect(start_x, shop_y, btn_w, btn_h, shop_color);
        fb.draw3DRect(start_x, shop_y, btn_w, btn_h, rgb(0x80, 0x60, 0xB0), rgb(0xC0, 0xA0, 0xE0));
        fb.drawTextTransparent(start_x + 20, shop_y + 30, "Purble", rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(start_x + 20, shop_y + 50, "Shop", rgb(0xFF, 0xFF, 0xFF));

        // Rubber Duck button
        const duck_x = start_x + btn_w + spacing;
        const duck_color = if (pp.hover_duck) rgb(0x90, 0xC0, 0x90) else rgb(0x70, 0xA0, 0x70);
        fb.fillRect(duck_x, shop_y, btn_w, btn_h, duck_color);
        fb.draw3DRect(duck_x, shop_y, btn_w, btn_h, rgb(0x60, 0x90, 0x60), rgb(0x90, 0xC0, 0x90));
        fb.drawTextTransparent(duck_x + 20, shop_y + 30, "Rubber", rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(duck_x + 30, shop_y + 50, "Ducks", rgb(0xFF, 0xFF, 0xFF));

        // Grid Pattern button
        const grid_x = start_x + 2 * (btn_w + spacing);
        const grid_color = if (pp.hover_grid) rgb(0x90, 0xB0, 0xC0) else rgb(0x70, 0x90, 0xA0);
        fb.fillRect(grid_x, shop_y, btn_w, btn_h, grid_color);
        fb.draw3DRect(grid_x, shop_y, btn_w, btn_h, rgb(0x60, 0x80, 0x90), rgb(0x90, 0xB0, 0xC0));
        fb.drawTextTransparent(grid_x + 10, shop_y + 30, "Grid", rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(grid_x + 10, shop_y + 50, "Pattern", rgb(0xFF, 0xFF, 0xFF));
    }

    fn renderShop(pp: *PurblePlaceGame, wx: i32, wy: i32, ww: i32, wh: i32) void {
        // Customer area
        fb.fillRect(wx + 50, wy + 60, 200, 200, rgb(0xFF, 0xF0, 0xE0));
        fb.draw3DRect(wx + 50, wy + 60, 200, 200, rgb(0xE0, 0xD0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        
        // Draw customer (simplified Purble character)
        const cx = wx + 150;
        const cy = wy + 160;
        fb.fillEllipse(cx, cy, 50, 60, rgb(0xFF, 0xA0, 0xC0)); // Body
        fb.fillEllipse(cx, cy - 70, 40, 40, rgb(0xFF, 0xC0, 0xD0)); // Head
        
        // Draw requested items
        var item_x: i32 = 60;
        if (pp.customer_order.hat) {
            fb.fillRect(wx + item_x, wy + 70, 30, 15, rgb(0xFF, 0x00, 0x00));
            item_x += 50;
        }
        if (pp.customer_order.glasses) {
            fb.fillRect(wx + item_x, wy + 110, 30, 10, rgb(0x00, 0x00, 0x00));
            item_x += 50;
        }
        if (pp.customer_order.bow_tie) {
            fb.fillRect(wx + item_x, wy + 140, 20, 10, rgb(0x00, 0x80, 0xFF));
            item_x += 50;
        }
        if (pp.customer_order.flower) {
            fb.fillEllipse(wx + item_x, wy + 100, 10, 10, rgb(0xFF, 0x00, 0xFF));
        }

        // Shop items (clickable)
        const item_y = wy + 280;
        const item_size: i32 = 60;
        const items = [_]struct { x: i32, hover: bool, name: []const u8 }{
            .{ .x = wx + 60, .hover = pp.hover_1, .name = "Hat" },
            .{ .x = wx + 140, .hover = pp.hover_2, .name = "Glasses" },
            .{ .x = wx + 220, .hover = pp.hover_3, .name = "Bow Tie" },
            .{ .x = wx + 300, .hover = pp.hover_4, .name = "Flower" },
        };
        
        var i: usize = 0;
        for (items) |item| {
            const item_color = if (pp.selected_items[i]) rgb(0x80, 0xFF, 0x80) else if (item.hover) rgb(0xE0, 0xE0, 0xFF) else rgb(0xD0, 0xD0, 0xE0);
            fb.fillRect(item.x, item_y, item_size, item_size, item_color);
            fb.draw3DRect(item.x, item_y, item_size, item_size, rgb(0xB0, 0xB0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(item.x + 5, item_y + 20, item.name, rgb(0x40, 0x40, 0x50));
            i += 1;
        }

        // OK button
        fb.fillRect(wx + ww - 100, wy + wh - 90, 80, 30, rgb(0x80, 0xD0, 0x80));
        fb.draw3DRect(wx + ww - 100, wy + wh - 90, 80, 30, rgb(0x60, 0xB0, 0x60), rgb(0xA0, 0xE0, 0xA0));
        fb.drawTextTransparent(wx + ww - 80, wy + wh - 80, "OK", rgb(0x30, 0x50, 0x30));
    }

    fn renderDuck(pp: *PurblePlaceGame, wx: i32, wy: i32, ww: i32, wh: i32) void {
        _ = wh;
        // Instructions
        var buf: [64]u8 = undefined;
        const instr = std.fmt.bufPrint(&buf, "Find the duck! Guesses: {d}/{d}", .{ pp.guess_count, pp.max_guesses }) catch "";
        fb.drawTextTransparent(wx + ww/2 - 150, wy + 60, instr, rgb(0x40, 0x60, 0x40));
        
        // Duck grid (3x3)
        const grid_size: i32 = 80;
        const gap: i32 = 10;
        const total_grid = 3 * grid_size + 2 * gap;
        const grid_x = wx + (ww - total_grid) / 2;
        const grid_y = wy + 100;
        
        var row: u8 = 0;
        while (row < 3) : (row += 1) {
            var col: u8 = 0;
            while (col < 3) : (col += 1) {
                const cell_x = grid_x + @as(i32, @intCast(col)) * (grid_size + gap);
                const cell_y = grid_y + @as(i32, @intCast(row)) * (grid_size + gap);
                
                fb.fillRect(cell_x, cell_y, grid_size, grid_size, rgb(0xE8, 0xF0, 0x98));
                fb.draw3DRect(cell_x, cell_y, grid_size, grid_size, rgb(0xC0, 0xC8, 0x78), rgb(0xFF, 0xFF, 0xFF));
                
                // Draw duck or placeholder
                const duck_x = cell_x + grid_size / 2;
                const duck_y = cell_y + grid_size / 2;
                
                // Duck body
                fb.fillEllipse(duck_x, duck_y + 10, 25, 20, rgb(0xFF, 0xFF, 0x00));
                // Duck head
                fb.fillEllipse(duck_x + 15, duck_y - 5, 15, 15, rgb(0xFF, 0xFF, 0x00));
                // Beak
                fb.fillRect(duck_x + 25, duck_y - 3, 10, 6, rgb(0xFF, 0xA0, 0x00));
                // Eye
                fb.fillEllipse(duck_x + 18, duck_y - 8, 3, 3, rgb(0x00, 0x00, 0x00));
            }
        }
    }

    fn renderGrid(pp: *PurblePlaceGame, wx: i32, wy: i32, ww: i32, wh: i32) void {
        // Instructions
        fb.drawTextTransparent(wx + ww/2 - 100, wy + 60, "Complete the pattern!", rgb(0x40, 0x50, 0x60));
        
        // Pattern display (top)
        const pattern_y = wy + 90;
        const cell_size: i32 = 30;
        const pattern_x = wx + 60;
        
        var pi: usize = 0;
        while (pi < 16) : (pi += 1) {
            const px = pattern_x + @as(i32, @intCast(pi % 4)) * cell_size;
            const py = pattern_y + @as(i32, @intCast(pi / 4)) * cell_size;
            
            const pcolor = if (pp.pattern[pi]) rgb(0x80, 0xC0, 0xE0) else rgb(0xD0, 0xD0, 0xD8);
            fb.fillRect(px, py, cell_size, cell_size, pcolor);
            fb.drawRect(px, py, cell_size, cell_size, rgb(0xA0, 0xA0, 0xB0));
        }

        // User input grid (bottom)
        const input_y = wy + 200;
        const input_x = wx + 60;
        
        var ii: usize = 0;
        while (ii < 16) : (ii += 1) {
            const ix = input_x + @as(i32, @intCast(ii % 4)) * cell_size;
            const iy = input_y + @as(i32, @intCast(ii / 4)) * cell_size;
            
            const icolor = if (pp.grid_selections[ii]) rgb(0x80, 0xC0, 0xE0) else rgb(0xD8, 0xE8, 0xF0);
            fb.fillRect(ix, iy, cell_size, cell_size, icolor);
            fb.draw3DRect(ix, iy, cell_size, cell_size, rgb(0xA0, 0xB0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
        }

        // Submit button
        fb.fillRect(wx + ww - 120, wy + wh - 90, 100, 30, rgb(0x80, 0xC0, 0x80));
        fb.draw3DRect(wx + ww - 120, wy + wh - 90, 100, 30, rgb(0x60, 0xA0, 0x60), rgb(0xA0, 0xE0, 0xA0));
        fb.drawTextTransparent(wx + ww - 100, wy + wh - 80, "Submit", rgb(0x30, 0x50, 0x30));
    }
};
