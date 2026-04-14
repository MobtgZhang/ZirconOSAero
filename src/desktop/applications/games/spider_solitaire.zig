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
// Module: src/desktop/applications/games/spider_solitaire.zig
// Purpose: Spider Solitaire card game
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

pub const SpiderSolitaireGame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    tableaus: [10][20]Card,
    tableau_counts: [10]u8,
    stock_count: [5]u8,
    foundations: [8]u8,
    moves: u32,
    score: i32,
    game_won: bool,
    selected_tableau: i32,
    selected_card_index: i32,
    difficulty: u8, // 1 = 1 suit, 2 = 2 suits, 4 = 4 suits
    hover_new: bool,
    hover_deal: bool,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) SpiderSolitaireGame {
        return .{
            .x = x_pos, .y = y_pos,
            .width = 900, .height = 600,
            .visible = true, .caption_hover = .none,
            .tableaus = undefined,
            .tableau_counts = [_]u8{0} ** 10,
            .stock_count = [_]u8{5} ** 5,
            .foundations = [_]u8{0} ** 8,
            .moves = 0, .score = 500, .game_won = false,
            .selected_tableau = -1, .selected_card_index = -1,
            .difficulty = 1,
            .hover_new = false, .hover_deal = false,
        };
    }

    pub fn newGame(sg: *SpiderSolitaireGame) void {
        sg.moves = 0;
        sg.score = 500;
        sg.game_won = false;
        sg.selected_tableau = -1;
        sg.selected_card_index = -1;

        for (0..10) |c| sg.tableau_counts[c] = 0;
        for (0..5) |c| sg.stock_count[c] = 5;
        for (0..8) |f| sg.foundations[f] = 0;

        // Create deck based on difficulty
        const num_suits: u8 = sg.difficulty;
        var deck: [104]Card = undefined;
        var deck_idx: u16 = 0;

        // Each suit has 8 complete sets of cards (2x standard deck)
        var suit_count: u8 = 0;
        while (suit_count < num_suits) : (suit_count += 1) {
            for (1..14) |v| {
                var copies: u8 = 0;
                while (copies < 8) : (copies += 1) {
                    deck[deck_idx] = .{
                        .suit = @enumFromInt(suit_count),
                        .value = @enumFromInt(v),
                        .face_up = true,
                    };
                    deck_idx += 1;
                }
            }
        }

        // Fisher-Yates shuffle
        const time_seed = @as(u64, @bitCast(std.time.nanoTimestamp()));
        var rng = std.rand.DefaultPrng.init(time_seed);
        deck_idx = 104;
        while (deck_idx > 1) {
            deck_idx -= 1;
            const j = rng.random().int(u16, deck_idx);
            const temp = deck[deck_idx];
            deck[deck_idx] = deck[j];
            deck[j] = temp;
        }

        // Deal to tableaus
        deck_idx = 0;
        // First 54 cards: 6 cards to first 4 columns, 5 cards to remaining 6 columns
        for (0..6) |col| {
            const num_cards: u8 = if (col < 4) 6 else 5;
            for (0..num_cards) |row| {
                sg.tableaus[col][row] = deck[deck_idx];
                // Face up only the top card
                if (row != num_cards - 1) {
                    sg.tableaus[col][row].face_up = false;
                }
                deck_idx += 1;
            }
            sg.tableau_counts[col] = num_cards;
        }
        for (6..10) |col| {
            for (0..5) |row| {
                sg.tableaus[col][row] = deck[deck_idx];
                sg.tableaus[col][row].face_up = false;
                deck_idx += 1;
            }
            sg.tableau_counts[col] = 5;
        }

        // Remaining cards go to stock (10 piles of 5 each)
        for (0..5) |pile| {
            sg.stock_count[pile] = 5;
        }
    }

    fn isRed(suit: Suit) bool {
        return suit == .hearts or suit == .diamonds;
    }

    fn canMoveToTableau(card: Card, target: Card) bool {
        if (!target.face_up) return false;
        if (isRed(card.suit) == isRed(target.suit)) return false;
        return @intFromEnum(card.value) == @intFromEnum(target.value) + 1;
    }

    fn isSequence(tableau: []const Card, start_idx: usize, count: u8) bool {
        if (start_idx + count > tableau.len) return false;
        var i: usize = start_idx;
        while (i < start_idx + count - 1) : (i += 1) {
            const curr = tableau[i];
            const next = tableau[i + 1];
            if (!curr.face_up) return false;
            if (!canMoveToTableau(curr, next)) return false;
        }
        return true;
    }

    pub fn handleClick(sg: *SpiderSolitaireGame, px: i32, py: i32) void {
        const wx = sg.x;
        const wy = sg.y;
        const ww = sg.width;

        // Check stock buttons (bottom right)
        const stock_start_x = wx + ww - 250;
        const stock_y = wy + 80;
        const btn_w: i32 = 40;
        const btn_h: i32 = 30;

        for (0..5) |i| {
            const bx = stock_start_x + @as(i32, @intCast(i)) * (btn_w + 5);
            if (px >= bx and px < bx + btn_w and py >= stock_y and py < stock_y + btn_h) {
                if (sg.stock_count[i] > 0) {
                    // Deal one card to each tableau
                    for (0..10) |col| {
                        if (sg.tableau_counts[col] < 20) {
                            sg.tableaus[col][sg.tableau_counts[col]] = .{
                                .suit = @enumFromInt(i),
                                .value = @enumFromInt((sg.stock_count[i] % 13) + 1),
                                .face_up = true,
                            };
                            sg.tableau_counts[col] += 1;
                        }
                    }
                    sg.stock_count[i] -= 1;
                    sg.moves += 1;
                    sg.score -= 10;
                    sg.checkCompleteSequences();
                }
                return;
            }
        }

        // Check tableaus
        const tableau_w: i32 = 80;
        const tableau_start_x = wx + 30;
        const tableau_y = wy + 130;
        const card_h: i32 = 22;
        const gap: i32 = 5;

        for (0..10) |col| {
            const tx = tableau_start_x + @as(i32, @intCast(col)) * (tableau_w + gap);

            if (px >= tx and px < tx + tableau_w) {
                if (sg.tableau_counts[col] == 0) {
                    // Empty column - only kings can be placed
                    if (sg.selected_tableau >= 0) {
                        const sel_col = @as(usize, @intCast(sg.selected_tableau));
                        const sel_idx = @as(usize, @intCast(sg.selected_card_index));
                        if (sg.tableau_counts[sel_col] > sel_idx) {
                            const card = sg.tableaus[sel_col][sel_idx];
                            if (@intFromEnum(card.value) == 13) {
                                const count = sg.tableau_counts[sel_col] - sel_idx;
                                var j: usize = 0;
                                while (j < count) : (j += 1) {
                                    sg.tableaus[col][j] = sg.tableaus[sel_col][sel_idx + j];
                                }
                                sg.tableau_counts[col] = @as(u8, @intCast(count));
                                sg.tableau_counts[sel_col] = @as(u8, @intCast(sel_idx));
                                sg.moves += 1;
                                sg.selected_tableau = -1;
                                sg.selected_card_index = -1;
                            }
                        }
                    }
                    return;
                }

                const last_card_idx = @as(i32, @intCast(sg.tableau_counts[col])) - 1;
                const click_y_rel = py - tableau_y;
                var card_idx = @divTrunc(click_y_rel, card_h);
                if (card_idx < 0) card_idx = 0;
                if (card_idx > last_card_idx) card_idx = last_card_idx;

                if (sg.selected_tableau >= 0) {
                    // Try to move selected cards
                    const sel_col = @as(usize, @intCast(sg.selected_tableau));
                    const sel_idx = @as(usize, @intCast(sg.selected_card_index));

                    if (sg.tableau_counts[sel_col] > sel_idx) {
                        const moving_card = sg.tableaus[sel_col][sel_idx];
                        const target_card = sg.tableaus[col][@as(usize, @intCast(card_idx))];
                        if (sg.canMoveToTableau(moving_card, target_card)) {
                            const count = sg.tableau_counts[sel_col] - sel_idx;
                            var j: usize = 0;
                            while (j < count) : (j += 1) {
                                sg.tableaus[col][sg.tableau_counts[col]] = sg.tableaus[sel_col][sel_idx + j];
                                sg.tableaus[col][sg.tableau_counts[col]].face_up = true;
                                sg.tableau_counts[col] += 1;
                            }
                            sg.tableau_counts[sel_col] = @as(u8, @intCast(sel_idx));
                            sg.moves += 1;
                            sg.selected_tableau = -1;
                            sg.selected_card_index = -1;
                            sg.flipTopCard(col);
                        }
                    }
                } else {
                    // Select card
                    sg.selected_tableau = @as(i32, @intCast(col));
                    sg.selected_card_index = card_idx;
                }
                return;
            }
        }
    }

    fn flipTopCard(sg: *SpiderSolitaireGame, col: usize) void {
        if (sg.tableau_counts[col] > 0) {
            sg.tableaus[col][sg.tableau_counts[col] - 1].face_up = true;
        }
    }

    fn checkCompleteSequences(sg: *SpiderSolitaireGame) void {
        for (0..10) |col| {
            if (sg.tableau_counts[col] >= 13) {
                const last_idx = sg.tableau_counts[col] - 1;
                var is_king_to_ace = true;
                const king_int: u8 = @intFromEnum(CardValue.king);
                for (0..12) |i| {
                    const card = sg.tableaus[col][last_idx - 12 + i];
                    const expected_value: u8 = king_int - @as(u8, @intCast(i));
                    if (@intFromEnum(card.value) != expected_value) {
                        is_king_to_ace = false;
                        break;
                    }
                }
                if (is_king_to_ace) {
                    sg.tableau_counts[col] -= 13;
                    sg.score += 100;
                    sg.flipTopCard(col);
                }
            }
        }
    }

    pub fn render(sg: *SpiderSolitaireGame, t: *const theme_mod.ThemeColors) void {
        if (!sg.visible) return;
        _ = t;

        const wx = sg.x;
        const wy = sg.y;
        const ww = sg.width;
        const wh = sg.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 6, "Spider Solitaire", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (sg.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 80, rgb(0x0B, 0x6E, 0x15));
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));

        // Draw empty foundation slots (top right)
        const found_x = wx + ww - 200;
        const found_y = wy + 40;
        const found_w: i32 = 50;

        fb.drawTextTransparent(found_x - 80, found_y + 10, "Completed:", rgb(0xFF, 0xFF, 0xFF));
        for (0..8) |f| {
            const fx = found_x + @as(i32, @intCast(f)) * (found_w + 5);
            fb.draw3DRect(fx, found_y, found_w, 35, rgb(0xFF, 0xFF, 0xFF), rgb(0x80, 0x80, 0x80));
            if (sg.foundations[f] > 0) {
                fb.drawTextTransparent(fx + 15, found_y + 10, "K->A", rgb(0x00, 0x80, 0x00));
            }
        }

        // Stock buttons (bottom right)
        const stock_start_x = wx + ww - 250;
        const stock_y = wy + 80;

        fb.drawTextTransparent(stock_start_x, stock_y - 20, "Stock:", rgb(0xFF, 0xFF, 0xFF));
        for (0..5) |i| {
            const bx = stock_start_x + @as(i32, @intCast(i)) * 45;
            const btn_color = if (sg.stock_count[i] > 0) rgb(0x60, 0x80, 0xC0) else rgb(0x50, 0x50, 0x50);
            fb.fillRect(bx, stock_y, 40, 30, btn_color);
            fb.drawRect(bx, stock_y, 40, 30, rgb(0x40, 0x60, 0xA0));

            var count_buf: [8]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{sg.stock_count[i]}) catch "";
            fb.drawTextTransparent(bx + 12, stock_y + 8, count_str, rgb(0xFF, 0xFF, 0xFF));
        }

        // Tableaus
        const tableau_w: i32 = 80;
        const tableau_start_x = wx + 30;
        const tableau_y = wy + 130;
        const card_h: i32 = 22;
        const gap: i32 = 5;

        for (0..10) |col| {
            const tx = tableau_start_x + @as(i32, @intCast(col)) * (tableau_w + gap);

            for (0..sg.tableau_counts[col]) |row| {
                const card = sg.tableaus[col][row];
                const ty = tableau_y + @as(i32, @intCast(row)) * card_h;
                const is_selected = sg.selected_tableau == @as(i32, @intCast(col)) and @as(i32, @intCast(row)) >= sg.selected_card_index;

                if (is_selected) {
                    fb.fillRect(tx + 2, ty + 2, tableau_w - 4, card_h - 2, rgb(0xFF, 0xFF, 0x00));
                }

                sg.drawCard(tx + 2, ty + 2, card);
            }

            // Empty slot indicator
            if (sg.tableau_counts[col] == 0) {
                fb.draw3DRect(tx, tableau_y, tableau_w, card_h, rgb(0x80, 0x80, 0x80), rgb(0x40, 0x40, 0x40));
            }
        }

        // Status bar
        const sy = wy + wh - 45;
        fb.fillRect(wx, sy, ww, 45, rgb(0xF0, 0xF4, 0xF8));
        fb.fillRect(wx, sy, ww, 1, rgb(0xC0, 0xC8, 0xD8));

        var buf: [32]u8 = undefined;
        const moves_str = std.fmt.bufPrint(&buf, "Moves: {d}", .{sg.moves}) catch "";
        fb.drawTextTransparent(wx + 8, sy + 8, moves_str, rgb(0x40, 0x40, 0x50));

        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, "Score: {d}", .{sg.score}) catch "";
        fb.drawTextTransparent(wx + 120, sy + 8, score_str, rgb(0x40, 0x40, 0x50));

        // Difficulty buttons
        const diff_x = wx + 250;
        const diff_y = sy + 5;
        fb.drawTextTransparent(diff_x, diff_y + 8, "Difficulty:", rgb(0x40, 0x40, 0x50));

        const btn_names = [_][]const u8{ "1-Suit", "2-Suit", "4-Suit" };
        for (0..3) |i| {
            const bx = diff_x + 90 + @as(i32, @intCast(i)) * 80;
            const is_active = @as(u8, @intCast(i)) + 1 == sg.difficulty;
            const btn_color = if (is_active) rgb(0x60, 0x90, 0x60) else rgb(0xE0, 0xE0, 0xE0);
            fb.fillRect(bx, diff_y, 70, 28, btn_color);
            fb.draw3DRect(bx, diff_y, 70, 28, rgb(0x80, 0x80, 0x80), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(bx + 5, diff_y + 8, btn_names[i], rgb(0x20, 0x20, 0x30));
        }

        // New Game button
        const new_btn_x = wx + ww - 120;
        const new_btn_y = sy + 8;
        const new_color = if (sg.hover_new) rgb(0x60, 0xB0, 0x60) else rgb(0x40, 0x90, 0x40);
        fb.fillRect(new_btn_x, new_btn_y, 100, 28, new_color);
        fb.draw3DRect(new_btn_x, new_btn_y, 100, 28, rgb(0x30, 0x70, 0x30), rgb(0x80, 0xE0, 0x80));
        fb.drawTextTransparent(new_btn_x + 25, new_btn_y + 8, "New Game", rgb(0xFF, 0xFF, 0xFF));

        // Win overlay
        if (sg.game_won) {
            fb.fillRect(wx + 200, wy + 200, ww - 400, 150, rgb(0xE0, 0xF0, 0xE0));
            fb.draw3DRect(wx + 200, wy + 200, ww - 400, 150, rgb(0xA0, 0xC0, 0xA0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(wx + ww/2 - 80, wy + 240, "Congratulations!", rgb(0x00, 0x80, 0x00));
            fb.drawTextTransparent(wx + ww/2 - 100, wy + 280, "You won Spider Solitaire!", rgb(0x40, 0x60, 0x40));
        }
    }

    fn drawCard(sg: *SpiderSolitaireGame, x: i32, y: i32, card: Card) void {
        _ = sg;
        const card_w: i32 = 75;
        const card_h: i32 = 20;

        const card_bg = rgb(0xFF, 0xFF, 0xFF);
        fb.fillRect(x, y, card_w, card_h, card_bg);
        fb.drawRect(x, y, card_w, card_h, rgb(0x80, 0x80, 0x80));

        if (!card.face_up) {
            fb.fillRect(x + 2, y + 2, card_w - 4, card_h - 4, rgb(0x20, 0x40, 0x80));
            // Draw pattern
            for (0..3) |i| {
                fb.fillRect(x + 4 + @as(i32, @intCast(i)) * 18, y + 4, 14, 12, rgb(0x30, 0x60, 0xA0));
            }
            return;
        }

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

        fb.drawTextTransparent(x + 2, y + 2, value_str, text_color);
        fb.drawTextTransparent(x + card_w - 14, y + 2, suit_str, text_color);
    }
};
