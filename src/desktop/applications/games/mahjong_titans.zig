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
// Module: src/desktop/applications/games/mahjong_titans.zig
// Purpose: Mahjong Titans - Tile matching solitaire game
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

/// Tile suit types
pub const TileSuit = enum {
    bamboo,
    circle,
    character,
    wind,
    dragon,
    flower,
};

/// Tile type
pub const TileType = struct {
    suit: TileSuit,
    value: u8,
    match_id: u8,
};

/// Mahjong Titans game
pub const MahjongTitansGame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    
    tiles: [144]?TileType,
    tile_count: usize,
    selected_tile: i32,
    
    score: i32,
    moves: u32,
    game_over: bool,
    game_won: bool,
    difficulty: Difficulty,
    
    hover_tile: i32,
    hover_new: bool,
    hover_hint: bool,
    hover_shuffle: bool,

    pub const Difficulty = enum { easy, medium, hard };
    
    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) MahjongTitansGame {
        return .{
            .x = x_pos, .y = y_pos,
            .width = 640, .height = 520,
            .visible = true, .caption_hover = .none,
            .tiles = undefined, .tile_count = 0,
            .selected_tile = -1,
            .score = 0, .moves = 0,
            .game_over = false, .game_won = false,
            .difficulty = .medium,
            .hover_tile = -1, .hover_new = false,
            .hover_hint = false, .hover_shuffle = false,
        };
    }

    pub fn newGame(mt: *MahjongTitansGame) void {
        mt.score = 0;
        mt.moves = 0;
        mt.game_over = false;
        mt.game_won = false;
        mt.selected_tile = -1;
        
        mt.generateTiles();
    }

    pub fn generateTiles(mt: *MahjongTitansGame) void {
        mt.tile_count = 0;
        var match_id: u8 = 0;
        
        // Basic tiles (4 of each)
        const basic_suits = [_]TileSuit{ .bamboo, .circle, .character };
        for (basic_suits) |suit| {
            var val: u8 = 1;
            while (val <= 9) : (val += 1) {
                var i: u8 = 0;
                while (i < 4) : (i += 1) {
                    if (mt.tile_count < mt.tiles.len) {
                        mt.tiles[mt.tile_count] = .{
                            .suit = suit,
                            .value = val,
                            .match_id = match_id,
                        };
                        mt.tile_count += 1;
                    }
                }
                match_id += 1;
            }
        }
        
        // Wind tiles (4 of each, 16 total)
        const winds = [_]u8{ 1, 2, 3, 4 }; // East, South, West, North
        for (winds) |wind| {
            var i: u8 = 0;
            while (i < 4) : (i += 1) {
                if (mt.tile_count < mt.tiles.len) {
                    mt.tiles[mt.tile_count] = .{
                        .suit = .wind,
                        .value = wind,
                        .match_id = match_id,
                    };
                    mt.tile_count += 1;
                }
            }
            match_id += 1;
        }
        
        // Dragon tiles (4 of each, 12 total)
        const dragons = [_]u8{ 1, 2, 3 }; // Red, Green, White
        for (dragons) |dragon| {
            var i: u8 = 0;
            while (i < 4) : (i += 1) {
                if (mt.tile_count < mt.tiles.len) {
                    mt.tiles[mt.tile_count] = .{
                        .suit = .dragon,
                        .value = dragon,
                        .match_id = match_id,
                    };
                    mt.tile_count += 1;
                }
            }
            match_id += 1;
        }
        
        // Fill remaining with flower tiles (for matching variety)
        while (mt.tile_count < 144 and match_id < 255) : (match_id += 1) {
            var i: u8 = 0;
            while (i < 4) : (i += 1) {
                if (mt.tile_count < mt.tiles.len) {
                    mt.tiles[mt.tile_count] = .{
                        .suit = .flower,
                        .value = match_id,
                        .match_id = match_id,
                    };
                    mt.tile_count += 1;
                }
            }
        }
        
        // Shuffle tiles
        mt.shuffleTiles();
        
        // Remove pairs based on difficulty
        var remove_count: usize = switch (mt.difficulty) {
            .easy => 72,
            .medium => 48,
            .hard => 24,
        };
        
        while (remove_count > 0 and mt.tile_count > 0) : (remove_count -= 1) {
            mt.tile_count -= 1;
            mt.tiles[mt.tile_count] = null;
        }
    }

    pub fn shuffleTiles(mt: *MahjongTitansGame) void {
        const seed = @as(u64, @bitCast(std.time.nanoTimestamp()));
        const rng = std.rand.DefaultPrng.init(seed);
        
        var i: usize = mt.tile_count;
        while (i > 1) : (i -= 1) {
            const j = rng.random().int(usize, i);
            const temp = mt.tiles[i - 1];
            mt.tiles[i - 1] = mt.tiles[j];
            mt.tiles[j] = temp;
        }
    }

    pub fn handleTileClick(mt: *MahjongTitansGame, tile_idx: i32) void {
        if (tile_idx < 0 or tile_idx >= @as(i32, @intCast(mt.tile_count))) return;
        if (mt.tiles[@as(usize, @intCast(tile_idx))] == null) return;
        
        if (mt.selected_tile == -1) {
            mt.selected_tile = tile_idx;
        } else {
            if (mt.selected_tile == tile_idx) {
                mt.selected_tile = -1;
            } else {
                const sel = mt.selected_tile;
                const sel_tile = mt.tiles[@as(usize, @intCast(sel))];
                const click_tile = mt.tiles[@as(usize, @intCast(tile_idx))];
                
                if (sel_tile != null and click_tile != null) {
                    if (sel_tile.?.match_id == click_tile.?.match_id) {
                        // Match found
                        mt.tiles[@as(usize, @intCast(sel))] = null;
                        mt.tiles[@as(usize, @intCast(tile_idx))] = null;
                        mt.score += 100;
                        mt.moves += 1;
                        
                        // Check for win
                        var all_empty = true;
                        for (mt.tiles) |tile| {
                            if (tile != null) {
                                all_empty = false;
                                break;
                            }
                        }
                        if (all_empty) {
                            mt.game_won = true;
                            mt.score += 1000;
                        }
                    } else {
                        // No match
                        mt.score = @max(0, mt.score - 10);
                        mt.moves += 1;
                    }
                }
                mt.selected_tile = -1;
            }
        }
    }

    pub fn findHint(mt: *MahjongTitansGame) void {
        // Find first pair
        var i: usize = 0;
        while (i < mt.tile_count) : (i += 1) {
            if (mt.tiles[i] == null) continue;
            
            var j: usize = i + 1;
            while (j < mt.tile_count) : (j += 1) {
                if (mt.tiles[j] == null) continue;
                
                if (mt.tiles[i].?.match_id == mt.tiles[j].?.match_id) {
                    mt.selected_tile = @as(i32, @intCast(i));
                    mt.hover_tile = @as(i32, @intCast(j));
                    return;
                }
            }
        }
    }

    pub fn shuffleRemaining(mt: *MahjongTitansGame) void {
        // Collect remaining tiles
        var remaining: [144]?TileType = undefined;
        var count: usize = 0;
        
        for (mt.tiles) |tile| {
            if (tile != null) {
                remaining[count] = tile;
                count += 1;
            }
        }
        
        // Reset all tiles
        for (&mt.tiles) |*tile| {
            tile.* = null;
        }
        
        // Shuffle remaining
        const seed = @as(u64, @bitCast(std.time.nanoTimestamp()));
        const rng = std.rand.DefaultPrng.init(seed);
        
        var idx: usize = count;
        while (idx > 1) : (idx -= 1) {
            const j = rng.random().int(usize, idx);
            const temp = remaining[idx - 1];
            remaining[idx - 1] = remaining[j];
            remaining[j] = temp;
        }
        
        // Place back
        mt.tile_count = count;
        var k: usize = 0;
        for (remaining[0..count]) |tile| {
            mt.tiles[k] = tile;
            k += 1;
        }
        
        mt.score = @max(0, mt.score - 50);
    }

    pub fn render(mt: *MahjongTitansGame, t: *const theme_mod.ThemeColors) void {
        if (!mt.visible) return;
        _ = t;

        const wx = mt.x;
        const wy = mt.y;
        const ww = mt.width;
        const wh = mt.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x20, 0x80, 0x60), rgb(0x30, 0xA0, 0x80));
        fb.drawTextTransparent(wx + 8, wy + 6, "Mahjong Titans", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (mt.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 100, rgb(0xE8, 0xF0, 0xE0));
        fb.draw3DRect(wx, wy, ww, wh, rgb(0x60, 0x90, 0x70), rgb(0x20, 0x60, 0x40));

        // Stats bar
        var buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&buf, "Score: {d}", .{mt.score}) catch "";
        fb.drawTextTransparent(wx + 8, wy + 38, score_str, rgb(0x20, 0x50, 0x30));

        var moves_buf: [32]u8 = undefined;
        const moves_str = std.fmt.bufPrint(&moves_buf, "Moves: {d}", .{mt.moves}) catch "";
        fb.drawTextTransparent(wx + ww / 2 - 40, wy + 38, moves_str, rgb(0x20, 0x50, 0x30));

        // Render tiles
        const tile_w: i32 = 50;
        const tile_h: i32 = 70;
        const gap_x: i32 = 4;
        const gap_y: i32 = 4;
        
        // Calculate grid dimensions (aim for roughly square)
        const cols: i32 = 12;
        const rows: i32 = (@as(i32, @intCast(mt.tile_count)) + cols - 1) / cols;
        
        const grid_w = cols * (tile_w + gap_x) - gap_x;
        const start_x = wx + (ww - grid_w) / 2;
        const start_y = wy + 60;
        
        var tile_idx: usize = 0;
        var row: i32 = 0;
        while (row < rows) : (row += 1) {
            var col: i32 = 0;
            while (col < cols) : (col += 1) {
                if (tile_idx >= mt.tile_count) break;
                
                const tile = mt.tiles[tile_idx];
                if (tile != null) {
                    const tx = start_x + col * (tile_w + gap_x);
                    const ty = start_y + row * (tile_h + gap_y);
                    
                    const is_selected = @as(i32, @intCast(tile_idx)) == mt.selected_tile;
                    const is_hint = @as(i32, @intCast(tile_idx)) == mt.hover_tile;
                    
                    var tile_color = rgb(0xFF, 0xFF, 0xE8);
                    if (is_selected) {
                        tile_color = rgb(0xFF, 0xE0, 0x80);
                    } else if (is_hint) {
                        tile_color = rgb(0xC0, 0xFF, 0xC0);
                    }
                    
                    // Draw tile shadow
                    fb.fillRect(tx + 2, ty + 2, tile_w, tile_h, rgb(0x80, 0x80, 0x60));
                    // Draw tile body
                    fb.fillRect(tx, ty, tile_w, tile_h, tile_color);
                    fb.draw3DRect(tx, ty, tile_w, tile_h, rgb(0xD0, 0xD0, 0xB0), rgb(0xFF, 0xFF, 0xFF));
                    
                    // Draw tile symbol
                    const sym_x = tx + tile_w / 2;
                    const sym_y = ty + tile_h / 2 - 5;
                    
                    const sym_color = switch (tile.?.suit) {
                        .bamboo => rgb(0x00, 0x80, 0x00),
                        .circle => rgb(0x00, 0x00, 0xA0),
                        .character => rgb(0xA0, 0x00, 0x00),
                        .wind => rgb(0x40, 0x40, 0x40),
                        .dragon => switch (tile.?.value) {
                            1 => rgb(0xE0, 0x00, 0x00),
                            2 => rgb(0x00, 0x80, 0x00),
                            else => rgb(0x60, 0x60, 0x60),
                        },
                        .flower => rgb(0xC0, 0x00, 0xC0),
                    };
                    
                    // Draw simple tile indicator
                    const symbol: []const u8 = switch (tile.?.suit) {
                        .bamboo => "B",
                        .circle => "C",
                        .character => "N",
                        .wind => switch (tile.?.value) {
                            1 => "E", 2 => "S", 3 => "W", else => "N",
                        },
                        .dragon => switch (tile.?.value) {
                            1 => "R", 2 => "G", else => "W",
                        },
                        .flower => "F",
                    };
                    
                    var val_buf: [8]u8 = undefined;
                    const val_str = std.fmt.bufPrint(&val_buf, "{s}{d}", .{ symbol, tile.?.value }) catch symbol;
                    fb.drawTextTransparent(sym_x - 10, sym_y - 10, val_str, sym_color);
                }
                tile_idx += 1;
            }
        }

        // Status bar with buttons
        const sy = wy + wh - 55;
        fb.fillRect(wx, sy, ww, 55, rgb(0xD8, 0xE8, 0xD8));
        fb.fillRect(wx, sy, ww, 1, rgb(0xB0, 0xC0, 0xB0));

        // New Game button
        const btn_y = sy + 12;
        const btn_w: i32 = 90;
        const btn_h: i32 = 30;
        
        const new_color = if (mt.hover_new) rgb(0x80, 0xD0, 0x80) else rgb(0x60, 0xB0, 0x60);
        fb.fillRect(wx + 10, btn_y, btn_w, btn_h, new_color);
        fb.draw3DRect(wx + 10, btn_y, btn_w, btn_h, rgb(0x40, 0x90, 0x40), rgb(0x80, 0xE0, 0x80));
        fb.drawTextTransparent(wx + 25, btn_y + 8, "New Game", rgb(0x20, 0x40, 0x20));

        // Hint button
        const hint_color = if (mt.hover_hint) rgb(0xD0, 0xD0, 0x60) else rgb(0xB0, 0xB0, 0x40);
        fb.fillRect(wx + 110, btn_y, 70, btn_h, hint_color);
        fb.draw3DRect(wx + 110, btn_y, 70, btn_h, rgb(0x90, 0x90, 0x30), rgb(0xE0, 0xE0, 0x60));
        fb.drawTextTransparent(wx + 125, btn_y + 8, "Hint", rgb(0x40, 0x40, 0x20));

        // Shuffle button
        const shuffle_color = if (mt.hover_shuffle) rgb(0x60, 0xC0, 0xE0) else rgb(0x40, 0xA0, 0xC0);
        fb.fillRect(wx + 190, btn_y, 70, btn_h, shuffle_color);
        fb.draw3DRect(wx + 190, btn_y, 70, btn_h, rgb(0x30, 0x80, 0xA0), rgb(0x60, 0xE0, 0xFF));
        fb.drawTextTransparent(wx + 200, btn_y + 8, "Shuffle", rgb(0x20, 0x40, 0x50));

        // Game over / win overlay
        if (mt.game_won) {
            fb.fillRect(wx + 120, wy + 150, ww - 240, 180, rgb(0xE0, 0xF0, 0xE0));
            fb.draw3DRect(wx + 120, wy + 150, ww - 240, 180, rgb(0xA0, 0xC0, 0xA0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(wx + ww/2 - 50, wy + 180, "Congratulations!", rgb(0x00, 0x80, 0x00));
            fb.drawTextTransparent(wx + ww/2 - 80, wy + 220, "You cleared all tiles!", rgb(0x30, 0x60, 0x30));
            var final_buf: [48]u8 = undefined;
            const final_str = std.fmt.bufPrint(&final_buf, "Final Score: {d}", .{mt.score}) catch "";
            fb.drawTextTransparent(wx + ww/2 - 60, wy + 260, final_str, rgb(0x00, 0x50, 0x00));
        }

        if (mt.game_over) {
            fb.fillRect(wx + 120, wy + 150, ww - 240, 180, rgb(0xF0, 0xE0, 0xE0));
            fb.draw3DRect(wx + 120, wy + 150, ww - 240, 180, rgb(0xC0, 0xA0, 0xA0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(wx + ww/2 - 40, wy + 180, "Game Over", rgb(0x80, 0x00, 0x00));
            fb.drawTextTransparent(wx + ww/2 - 80, wy + 220, "No more moves available", rgb(0x60, 0x30, 0x30));
        }
    }
};
