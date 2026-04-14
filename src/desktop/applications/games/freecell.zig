// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/games/freecell.zig
// Purpose: FreeCell card game
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const Suit = enum(u8) {
    spades = 0,
    hearts = 1,
    clubs = 2,
    diamonds = 3,
};

pub const CardValue = enum(u8) {
    ace = 1, two = 2, three = 3, four = 4, five = 5,
    six = 6, seven = 7, eight = 8, nine = 9, ten = 10,
    jack = 11, queen = 12, king = 13,
};

pub const Card = struct {
    suit: Suit,
    value: CardValue,
    face_up: bool,
};

pub const FreeCellGame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    cascades: [8][19]Card,
    cascade_counts: [8]u8,
    free_cells: [4]?Card,
    home_cells: [4]?Card,
    moves: u32,
    score: i32,
    game_won: bool,
    selected_cascade: i32,
    selected_card_index: i32,
    hover_new: bool,
    hover_undo: bool,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) FreeCellGame {
        return .{
            .x = x_pos, .y = y_pos,
            .width = 800, .height = 580,
            .visible = true, .caption_hover = .none,
            .cascades = undefined,
            .cascade_counts = [_]u8{0} ** 8,
            .free_cells = [_]?Card{null} ** 4,
            .home_cells = [_]?Card{null} ** 4,
            .moves = 0, .score = 0, .game_won = false,
            .selected_cascade = -1, .selected_card_index = -1,
            .hover_new = false, .hover_undo = false,
        };
    }

    pub fn newGame(fc: *FreeCellGame) void {
        fc.moves = 0;
        fc.score = 0;
        fc.game_won = false;
        fc.selected_cascade = -1;
        fc.selected_card_index = -1;

        for (0..8) |c| fc.cascade_counts[c] = 0;
        for (0..4) |c| {
            fc.free_cells[c] = null;
            fc.home_cells[c] = null;
        }

        // Create and shuffle deck
        var deck: [52]Card = undefined;
        var deck_idx: u8 = 0;
        for (0..4) |s| {
            for (1..14) |v| {
                deck[deck_idx] = .{
                    .suit = @enumFromInt(s),
                    .value = @enumFromInt(v),
                    .face_up = true,
                };
                deck_idx += 1;
            }
        }

        // Fisher-Yates shuffle
        const time_seed = @as(u64, @bitCast(std.time.nanoTimestamp()));
        var rng = std.rand.DefaultPrng.init(time_seed);
        deck_idx = 52;
        while (deck_idx > 1) {
            deck_idx -= 1;
            const j = rng.random().int(u8, deck_idx);
            const temp = deck[deck_idx];
            deck[deck_idx] = deck[j];
            deck[j] = temp;
        }

        // Deal to cascades
        var card_idx: usize = 0;
        for (0..8) |col| {
            fc.cascade_counts[col] = 4;
            for (0..4) |row| {
                fc.cascades[col][row] = deck[card_idx];
                card_idx += 1;
            }
        }
    }

    fn isRed(suit: Suit) bool {
        return suit == .hearts or suit == .diamonds;
    }

    fn canMoveToCascade(card: Card, target: Card) bool {
        if (!target.face_up) return false;
        return @intFromEnum(card.value) == @intFromEnum(target.value) + 1;
    }

    fn canMoveToHome(cell: Card, home_idx: usize) bool {
        if (@intFromEnum(cell.suit) != home_idx) return false;
        return true;
    }

    pub fn handleClick(fc: *FreeCellGame, px: i32, py: i32) void {
        const wx = fc.x;
        const wy = fc.y;
        const ww = fc.width;

        // Check home cells (top right area)
        const home_cell_w: i32 = 70;
        const home_start_x = wx + ww - 310;
        const home_y = wy + 40;

        for (0..4) |i| {
            const cell_x = home_start_x + @as(i32, @intCast(i)) * (home_cell_w + 5);
            if (px >= cell_x and px < cell_x + home_cell_w and
                py >= home_y and py < home_y + 50) {
                if (fc.selected_cascade >= 0 and fc.selected_card_index >= 0) {
                    const col = @as(usize, @intCast(fc.selected_cascade));
                    const idx = fc.cascade_counts[col] - 1;
                    if (@as(i32, @intCast(idx)) == fc.selected_card_index) {
                        const card = fc.cascades[col][idx];
                        if (fc.canMoveToHome(card, i)) {
                            fc.home_cells[i] = card;
                            fc.cascade_counts[col] -= 1;
                            fc.moves += 1;
                            fc.score += 100;
                            fc.selected_cascade = -1;
                            fc.selected_card_index = -1;
                        }
                    }
                }
                return;
            }
        }

        // Check cascades (bottom area)
        const cascade_w: i32 = 85;
        const cascade_start_x = wx + 20;
        const cascade_y = wy + 110;
        const card_h: i32 = 25;

        for (0..8) |col| {
            const cx = cascade_start_x + @as(i32, @intCast(col)) * (cascade_w + 5);

            if (px >= cx and px < cx + cascade_w) {
                if (fc.cascade_counts[col] == 0) {
                    if (fc.selected_cascade >= 0) {
                        const sel_col = @as(usize, @intCast(fc.selected_cascade));
                        const sel_idx = @as(usize, @intCast(fc.selected_card_index));
                        if (fc.cascade_counts[sel_col] > sel_idx) {
                            const card = fc.cascades[sel_col][sel_idx];
                            if (@intFromEnum(card.value) == 13) {
                                const count = fc.cascade_counts[sel_col] - sel_idx;
                                var j: usize = 0;
                                while (j < count) : (j += 1) {
                                    fc.cascades[col][j] = fc.cascades[sel_col][sel_idx + j];
                                }
                                fc.cascade_counts[col] = @as(u8, @intCast(count));
                                fc.cascade_counts[sel_col] = @as(u8, @intCast(sel_idx));
                                fc.moves += 1;
                                fc.selected_cascade = -1;
                                fc.selected_card_index = -1;
                            }
                        }
                    }
                    return;
                }

                const last_card_idx = @as(i32, @intCast(fc.cascade_counts[col])) - 1;
                const click_y_rel = py - cascade_y;
                var card_idx = @divTrunc(click_y_rel, card_h);
                if (card_idx < 0) card_idx = 0;
                if (card_idx > last_card_idx) card_idx = last_card_idx;

                if (fc.selected_cascade >= 0) {
                    const sel_col = @as(usize, @intCast(fc.selected_cascade));
                    const sel_idx = @as(usize, @intCast(fc.selected_card_index));

                    if (fc.cascade_counts[sel_col] > sel_idx) {
                        const moving_card = fc.cascades[sel_col][sel_idx];
                        const target_card = fc.cascades[col][@as(usize, @intCast(card_idx))];
                        if (fc.canMoveToCascade(moving_card, target_card)) {
                            const count = fc.cascade_counts[sel_col] - sel_idx;
                            var j: usize = 0;
                            while (j < count) : (j += 1) {
                                fc.cascades[col][fc.cascade_counts[col]] = fc.cascades[sel_col][sel_idx + j];
                                fc.cascade_counts[col] += 1;
                            }
                            fc.cascade_counts[sel_col] = @as(u8, @intCast(sel_idx));
                            fc.moves += 1;
                            fc.selected_cascade = -1;
                            fc.selected_card_index = -1;
                        }
                    }
                } else {
                    fc.selected_cascade = @as(i32, @intCast(col));
                    fc.selected_card_index = card_idx;
                }
                return;
            }
        }
    }

    pub fn render(fc: *FreeCellGame, t: *const theme_mod.ThemeColors) void {
        if (!fc.visible) return;
        _ = t;

        const wx = fc.x;
        const wy = fc.y;
        const ww = fc.width;
        const wh = fc.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 6, "FreeCell", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (fc.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 80, rgb(0x0B, 0x6E, 0x15));
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));

        // Free cells (top left)
        const free_cell_w: i32 = 70;
        const free_start_x = wx + 30;
        const cell_y = wy + 40;

        fb.drawTextTransparent(free_start_x, cell_y - 15, "Free Cells", rgb(0xFF, 0xFF, 0xFF));

        for (0..4) |i| {
            const cell_x = free_start_x + @as(i32, @intCast(i)) * (free_cell_w + 5);
            fb.draw3DRect(cell_x, cell_y, free_cell_w, 50, rgb(0xFF, 0xFF, 0xFF), rgb(0x80, 0x80, 0x80));
            if (fc.free_cells[i]) |card| {
                fc.drawCard(cell_x + 2, cell_y + 2, card);
            }
        }

        // Home cells (top right)
        const home_cell_w: i32 = 70;
        const home_start_x = wx + ww - 310;

        fb.drawTextTransparent(home_start_x, cell_y - 15, "Home Cells", rgb(0xFF, 0xFF, 0xFF));

        const suit_names = [_][]const u8{ "S", "H", "C", "D" };
        for (0..4) |i| {
            const cell_x = home_start_x + @as(i32, @intCast(i)) * (home_cell_w + 5);
            fb.draw3DRect(cell_x, cell_y, home_cell_w, 50, rgb(0xFF, 0xFF, 0xFF), rgb(0x80, 0x80, 0x80));

            if (fc.home_cells[i]) |card| {
                fc.drawCard(cell_x + 2, cell_y + 2, card);
            } else {
                const color: u32 = if (i < 2) rgb(0xC0, 0x40, 0x40) else rgb(0x40, 0x40, 0x40);
                fb.drawTextTransparent(cell_x + 25, cell_y + 15, suit_names[i], color);
            }
        }

        // Cascades (bottom)
        const cascade_w: i32 = 85;
        const cascade_start_x = wx + 20;
        const cascade_y = wy + 110;
        const card_h: i32 = 25;

        for (0..8) |col| {
            const cx = cascade_start_x + @as(i32, @intCast(col)) * (cascade_w + 5);

            fb.fillRect(cx, cascade_y, cascade_w, wh - 160, rgb(0x08, 0x50, 0x0A));
            fb.drawRect(cx, cascade_y, cascade_w, wh - 160, rgb(0x0A, 0x60, 0x0C));

            for (0..fc.cascade_counts[col]) |row| {
                const card = fc.cascades[col][row];
                const cy = cascade_y + @as(i32, @intCast(row)) * card_h;
                const is_selected = fc.selected_cascade == @as(i32, @intCast(col)) and @as(i32, @intCast(row)) >= fc.selected_card_index;

                if (is_selected) {
                    fb.fillRect(cx + 2, cy + 2, cascade_w - 4, card_h - 2, rgb(0xFF, 0xFF, 0x00));
                }

                fc.drawCard(cx + 2, cy + 2, card);
            }
        }

        // Status bar
        const sy = wy + wh - 45;
        fb.fillRect(wx, sy, ww, 45, rgb(0xF0, 0xF4, 0xF8));
        fb.fillRect(wx, sy, ww, 1, rgb(0xC0, 0xC8, 0xD8));

        var buf: [32]u8 = undefined;
        const moves_str = std.fmt.bufPrint(&buf, "Moves: {d}", .{fc.moves}) catch "";
        fb.drawTextTransparent(wx + 8, sy + 8, moves_str, rgb(0x40, 0x40, 0x50));

        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, "Score: {d}", .{fc.score}) catch "";
        fb.drawTextTransparent(wx + 120, sy + 8, score_str, rgb(0x40, 0x40, 0x50));

        // New Game button
        const btn_x = wx + ww - 120;
        const btn_y = sy + 8;
        const btn_w: i32 = 100;
        const btn_h: i32 = 28;

        const new_color = if (fc.hover_new) rgb(0x60, 0xB0, 0x60) else rgb(0x40, 0x90, 0x40);
        fb.fillRect(btn_x, btn_y, btn_w, btn_h, new_color);
        fb.draw3DRect(btn_x, btn_y, btn_w, btn_h, rgb(0x30, 0x70, 0x30), rgb(0x80, 0xE0, 0x80));
        fb.drawTextTransparent(btn_x + 25, btn_y + 8, "New Game", rgb(0xFF, 0xFF, 0xFF));

        // Win overlay
        if (fc.game_won) {
            fb.fillRect(wx + 200, wy + 200, ww - 400, 150, rgb(0xE0, 0xF0, 0xE0));
            fb.draw3DRect(wx + 200, wy + 200, ww - 400, 150, rgb(0xA0, 0xC0, 0xA0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(wx + ww/2 - 80, wy + 240, "Congratulations!", rgb(0x00, 0x80, 0x00));
            fb.drawTextTransparent(wx + ww/2 - 100, wy + 280, "You won FreeCell!", rgb(0x40, 0x60, 0x40));
        }
    }

    fn drawCard(fc: *FreeCellGame, x: i32, y: i32, card: Card) void {
        _ = fc;
        const card_w: i32 = 80;
        const card_h: i32 = 22;

        fb.fillRect(x, y, card_w, card_h, rgb(0xFF, 0xFF, 0xFF));
        fb.drawRect(x, y, card_w, card_h, rgb(0x80, 0x80, 0x80));

        const text_color: u32 = if (isRed(card.suit)) rgb(0xC0, 0x20, 0x20) else rgb(0x20, 0x20, 0x20);
        const value_str = switch (card.value) {
            .ace => "A",
            .two => "2",
            .three => "3",
            .four => "4",
            .five => "5",
            .six => "6",
            .seven => "7",
            .eight => "8",
            .nine => "9",
            .ten => "10",
            .jack => "J",
            .queen => "Q",
            .king => "K",
        };
        const suit_str = switch (card.suit) {
            .spades => "S",
            .hearts => "H",
            .clubs => "C",
            .diamonds => "D",
        };

        fb.drawTextTransparent(x + 2, y + 3, value_str, text_color);
        fb.drawTextTransparent(x + card_w - 14, y + 3, suit_str, text_color);
    }
};
