// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/games/solitaire.zig
// Purpose: Klondike Solitaire game implementation
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const Suit = enum(u2) { hearts, diamonds, clubs, spades };
pub const CardValue = enum(u4) {
    ace = 1, two = 2, three = 3, four = 4, five = 5,
    six = 6, seven = 7, eight = 8, nine = 9, ten = 10,
    jack = 11, queen = 12, king = 13,
};

pub const Card = struct {
    suit: Suit,
    value: CardValue,
    face_up: bool,
    x: i32,
    y: i32,
};

pub const SolitaireGame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    cards: [52]Card,
    deck: [24]u8,
    deck_index: u8,
    waste_index: u8,
    tableau: [7][20]u8,
    tableau_count: [7]u8,
    foundations: [4]u8,
    game_state: GameState,
    score: i32,
    moves: u32,
    time_elapsed: u32,
    caption_hover: CaptionButtonType,
    dragging_card: ?DragInfo,
    anim_source_x: i32,
    anim_source_y: i32,
    anim_target_x: i32,
    anim_target_y: i32,
    anim_progress: f32,
    animating: bool,

    pub const GameState = enum(u8) { playing, won, _ };
    pub const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const DragInfo = struct { from_pile: PileType, card_index: u8, offset_x: i32, offset_y: i32 };
    pub const PileType = enum { tableau_0, tableau_1, tableau_2, tableau_3, tableau_4, tableau_5, tableau_6, waste, foundation_0, foundation_1, foundation_2, foundation_3 };

    pub fn create(x_pos: i32, y_pos: i32) SolitaireGame {
        var sol = SolitaireGame{
            .x = x_pos, .y = y_pos,
            .width = 700, .height = 550,
            .visible = true,
            .cards = undefined,
            .deck = undefined,
            .deck_index = 0,
            .waste_index = 0,
            .tableau = [_][20]u8{[_]u8{0} ** 20} ** 7,
            .tableau_count = [_]u8{0} ** 7,
            .foundations = [_]u8{0} ** 4,
            .game_state = .playing,
            .score = 0,
            .moves = 0,
            .time_elapsed = 0,
            .caption_hover = .none,
            .dragging_card = null,
            .anim_source_x = 0,
            .anim_source_y = 0,
            .anim_target_x = 0,
            .anim_target_y = 0,
            .anim_progress = 0,
            .animating = false,
        };
        sol.initDeck();
        return sol;
    }

    pub fn reset(s: *SolitaireGame) void {
        s.deck_index = 0;
        s.waste_index = 0;
        s.score = 0;
        s.moves = 0;
        s.time_elapsed = 0;
        s.game_state = .playing;
        s.foundations = [_]u8{0} ** 4;
        s.tableau_count = [_]u8{0} ** 7;
        s.dragging_card = null;
        s.animating = false;
        s.initDeck();
    }

    fn initDeck(s: *SolitaireGame) void {
        var idx: u8 = 0;
        const suits = [_]Suit{ .hearts, .diamonds, .clubs, .spades };
        for (suits) |suit| {
            for (1..14) |v| {
                s.cards[idx] = .{
                    .suit = suit,
                    .value = @enumFromInt(v),
                    .face_up = false,
                    .x = 0, .y = 0,
                };
                idx += 1;
            }
        }

        var seed: u32 = @truncate(@as(u64, @intFromPtr(s)));
        var i: u8 = 0;
        while (i < 52) : (i += 1) {
            seed = seed *% 1664525 +% 1013904223;
            const j = @as(u8, @truncate(seed % 52));
            const tmp = s.cards[i];
            s.cards[i] = s.cards[j];
            s.cards[j] = tmp;
        }

        var card_idx: u8 = 0;
        for (&s.tableau, 0..) |*col, c| {
            s.tableau_count[@intCast(c)] = @intCast(c + 1);
            var r: u8 = 0;
            while (r < s.tableau_count[@intCast(c)]) : (r += 1) {
                col[r] = card_idx;
                if (r == s.tableau_count[@intCast(c)] - 1) {
                    s.cards[col[r]].face_up = true;
                }
                card_idx += 1;
            }
        }
        s.deck_index = 0;
        s.waste_index = 24;
        var d: u8 = 0;
        while (d < 24) : (d += 1) {
            s.deck[d] = card_idx;
            card_idx += 1;
        }
    }

    pub fn drawFromDeck(s: *SolitaireGame) void {
        if (s.deck_index >= 24) {
            s.deck_index = 0;
            s.waste_index = 24;
            return;
        }
        s.deck_index += 1;
        s.waste_index = 24 + s.deck_index;
        s.moves += 1;
        s.score -= 5;
    }

    pub fn canAutoComplete(s: *const SolitaireGame) bool {
        for (s.tableau_count, 0..) |cnt, col| {
            if (cnt > 0) {
                const top_idx = s.tableau[col][cnt - 1];
                const top = s.cards[top_idx];
                if (!top.face_up) return false;
            }
        }
        for (s.foundations) |count| {
            if (count == 0) return false;
        }
        return true;
    }

    pub fn onDoubleClick(s: *SolitaireGame, pile: PileType, card_idx: u8) void {
        const card = switch (pile) {
            .waste => if (s.deck_index > 0) s.cards[s.deck[s.deck_index - 1]] else return,
            .tableau_0, .tableau_1, .tableau_2, .tableau_3, .tableau_4, .tableau_5, .tableau_6 => |col| blk: {
                const c = @intFromEnum(col);
                if (card_idx >= s.tableau_count[c]) return;
                break :blk s.cards[s.tableau[c][card_idx]];
            },
            else => return,
        };

        if (!card.face_up) return;
        if (card.value != .ace) return;

        const foundation_idx: usize = @intFromEnum(card.suit);
        if (s.foundations[foundation_idx] == 0) {
            s.foundations[foundation_idx] = 1;
            s.moves += 1;
            s.score += 10;

            // Remove from source
            switch (pile) {
                .waste => {},
                .tableau_0, .tableau_1, .tableau_2, .tableau_3, .tableau_4, .tableau_5, .tableau_6 => |col| {
                    const c = @intFromEnum(col);
                    if (s.tableau_count[c] > 0) {
                        s.tableau_count[c] -= 1;
                        if (s.tableau_count[c] > 0) {
                            const last_idx = s.tableau[c][s.tableau_count[c] - 1];
                            s.cards[last_idx].face_up = true;
                        }
                    }
                },
                else => return,
            }
        }
    }

    pub fn tick(s: *SolitaireGame) void {
        if (s.game_state == .playing) {
            s.time_elapsed += 1;
        }
        if (s.animating) {
            s.anim_progress += 0.15;
            if (s.anim_progress >= 1.0) {
                s.anim_progress = 1.0;
                s.animating = false;
            }
        }
    }

    pub fn render(s: *SolitaireGame, t: *const theme_mod.ThemeColors) void {
        if (!s.visible) return;
        s.renderBoard(t);
        s.renderDeck(t);
        s.renderWaste(t);
        s.renderFoundations(t);
        s.renderTableau(t);
        s.renderScoreAndTime(t);
    }

    fn renderBoard(s: *SolitaireGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const bx = s.x;
        const by = s.y;
        fb.fillRect(bx, by, s.width, s.height, rgb(0x00, 0x70, 0x00));
        var i: usize = 0;
        while (i < 2000) : (i += 1) {
            const px = bx + @as(i32, @intCast((i * 7) % s.width));
            const py = by + @as(i32, @intCast((i * 13) % s.height));
            fb.putPixel32(px, py, rgb(0x00, 0x50, 0x00));
        }
    }

    fn renderScoreAndTime(s: *SolitaireGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, "Score: {d}", .{s.score}) catch "";

        var time_buf: [32]u8 = undefined;
        const minutes = s.time_elapsed / 3600;
        const seconds = (s.time_elapsed / 60) % 60;
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}", .{ minutes, seconds }) catch "";

        fb.drawTextTransparent(s.x + 400, s.y + 10, score_str, rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(s.x + 520, s.y + 10, time_str, rgb(0xFF, 0xFF, 0xFF));
    }

    fn renderDeck(s: *SolitaireGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const r = cardRect(s, 10, 10);
        if (s.deck_index < 24) {
            s.renderCardBack(r.x, r.y);
            fb.drawTextTransparent(r.x + 20, r.y + 35, "Draw", rgb(0xFF, 0xFF, 0xFF));
        } else {
            fb.fillRect(r.x, r.y, r.w, r.h, rgb(0x00, 0x40, 0x00));
            fb.draw3DRect(r.x, r.y, r.w, r.h, rgb(0xFF, 0xFF, 0xFF), rgb(0x00, 0x60, 0x00));
            fb.drawTextTransparent(r.x + 12, r.y + 35, "Reset", rgb(0xFF, 0xFF, 0xFF));
        }
    }

    fn renderWaste(s: *SolitaireGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        if (s.deck_index == 0) return;
        const w_idx = s.deck_index - 1;
        if (w_idx >= 24) return;
        const card_idx = s.deck[w_idx];
        const card = s.cards[card_idx];
        const r = cardRect(s, 100, 10);
        s.renderCardFace(card, r.x, r.y);
    }

    fn renderFoundations(s: *SolitaireGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const suits = [_]Suit{ .hearts, .diamonds, .clubs, .spades };
        const suit_labels = [_][]const u8{ "H", "D", "C", "S" };

        for (suits, 0..) |suit, f| {
            const r = cardRect(s, 400 + @as(i32, @intCast(f)) * 75, 10);
            fb.fillRect(r.x, r.y, r.w, r.h, rgb(0x00, 0x40, 0x00));
            fb.draw3DRect(r.x, r.y, r.w, r.h, rgb(0xFF, 0xFF, 0xFF), rgb(0x00, 0x60, 0x00));

            if (s.foundations[f] > 0) {
                const card_idx_base = @as(u8, @intFromEnum(suit)) * 13;
                const top_value = s.foundations[f];
                const top_card = s.cards[card_idx_base + top_value - 1];
                s.renderCardFace(top_card, r.x, r.y);
            } else {
                fb.drawTextTransparent(r.x + 25, r.y + 35, suit_labels[f], rgb(0xFF, 0xFF, 0xFF));
            }
        }
    }

    fn renderTableau(s: *SolitaireGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        for (0..7) |c| {
            var card_y = s.y + 120;
            for (0..@as(usize, @intCast(s.tableau_count[c]))) |r| {
                const card_idx = s.tableau[c][r];
                const card = s.cards[card_idx];
                const card_x = s.x + 10 + @as(i32, @intCast(c)) * 75;
                if (card.face_up) {
                    s.renderCardFace(card, card_x, card_y);
                } else {
                    s.renderCardBack(card_x, card_y);
                }
                card_y += if (card.face_up) 20 else 15;
            }
        }
    }

    fn renderCardBack(cx: i32, cy: i32) void {
        fb.fillRect(cx, cy, 71, 96, rgb(0x20, 0x60, 0xC0));
        fb.draw3DRect(cx, cy, 71, 96, rgb(0x60, 0xA0, 0xE0), rgb(0x10, 0x30, 0x90));
        fb.drawRect(cx + 4, cy + 4, 63, 88, rgb(0x80, 0xB8, 0xF0));
        fb.drawRect(cx + 8, cy + 8, 55, 80, rgb(0x80, 0xB8, 0xF0));
    }

    fn renderCardFace(s: *SolitaireGame, cx: i32, cy: i32) void {
        _ = s;
        const is_red = true;

        fb.fillRect(cx, cy, 71, 96, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(cx, cy, 71, 96, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC0, 0xC0));

        if (is_red) {
            fb.drawTextTransparent(cx + 2, cy + 2, "A", rgb(0xCC, 0x00, 0x00));
            fb.drawTextTransparent(cx + 52, cy + 80, "A", rgb(0xCC, 0x00, 0x00));
            fb.drawTextTransparent(cx + 25, cy + 35, "[suit]", rgb(0xCC, 0x00, 0x00));
        } else {
            fb.drawTextTransparent(cx + 2, cy + 2, "A", rgb(0x00, 0x00, 0xCC));
            fb.drawTextTransparent(cx + 52, cy + 80, "A", rgb(0x00, 0x00, 0xCC));
            fb.drawTextTransparent(cx + 25, cy + 35, "[suit]", rgb(0x00, 0x00, 0xCC));
        }
    }

    fn cardRect(s: *const SolitaireGame, x_offset: i32, y_offset: i32) struct { x: i32, y: i32, w: i32, h: i32 } {
        return .{ .x = s.x + x_offset, .y = s.y + y_offset, .w = 71, .h = 96 };
    }
};
