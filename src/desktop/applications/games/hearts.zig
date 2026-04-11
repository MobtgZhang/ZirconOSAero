// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/games/hearts.zig
// Purpose: Hearts card game with AI opponents
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const HSuit = enum(u2) { hearts, diamonds, clubs, spades };
pub const HCardValue = enum(u4) { two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10, jack = 11, queen = 12, king = 13, ace = 14 };

pub const HCard = struct {
    suit: HSuit,
    value: HCardValue,
    dealt: bool,
};

pub const Player = struct {
    name: [16]u8,
    name_len: usize,
    hand: [13]HCard,
    hand_count: u8,
    score: i32,
    round_score: i32,
    is_human: bool,
};

pub const HeartsGame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    players: [4]Player,
    current_player: u8,
    trick_cards: [4]HCard,
    trick_players: [4]u8,
    trick_count: u8,
    trick_leader: u8,
    phase: HeartsPhase,
    round_score: i32,
    selected_card: i8,
    passing_direction: PassDirection,
    animating: bool,
    caption_hover: CaptionButtonType,

    pub const GameState = enum { waiting, playing, round_over };
    pub const HeartsPhase = enum { dealing, passing, playing, trick_end };
    pub const PassDirection = enum { left, right, across, none };
    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) HeartsGame {
        var hg = HeartsGame{
            .x = x_pos, .y = y_pos,
            .width = 800, .height = 600,
            .visible = true,
            .players = undefined,
            .current_player = 0,
            .trick_cards = undefined,
            .trick_players = undefined,
            .trick_count = 0,
            .trick_leader = 0,
            .phase = .dealing,
            .round_score = 0,
            .selected_card = -1,
            .passing_direction = .left,
            .animating = false,
            .caption_hover = .none,
        };
        hg.initGame();
        return hg;
    }

    pub fn initGame(hg: *HeartsGame) void {
        @memset(&hg.players, undefined);
        hg.players[0] = .{ .name = "You".*, .name_len = 3, .hand = undefined, .hand_count = 0, .score = 0, .round_score = 0, .is_human = true };
        hg.players[1] = .{ .name = "North".*, .name_len = 5, .hand = undefined, .hand_count = 0, .score = 0, .round_score = 0, .is_human = false };
        hg.players[2] = .{ .name = "West".*, .name_len = 4, .hand = undefined, .hand_count = 0, .score = 0, .round_score = 0, .is_human = false };
        hg.players[3] = .{ .name = "East".*, .name_len = 4, .hand = undefined, .hand_count = 0, .score = 0, .round_score = 0, .is_human = false };
        hg.current_player = 0;
        hg.phase = .dealing;
        hg.round_score = 0;
        hg.selected_card = -1;
        hg.trick_count = 0;
        hg.initDeck();
    }

    fn initDeck(hg: *HeartsGame) void {
        var deck: [52]HCard = undefined;
        var idx: u8 = 0;
        const suits = [_]HSuit{ .hearts, .diamonds, .clubs, .spades };
        for (suits) |suit| {
            for (2..15) |v| {
                deck[idx] = .{ .suit = suit, .value = @enumFromInt(v), .dealt = false };
                idx += 1;
            }
        }

        var seed: u32 = @truncate(@as(u64, @intFromPtr(hg)));
        var i: u8 = 0;
        while (i < 52) : (i += 1) {
            seed = seed *% 1664525 +% 1013904223;
            const j = @as(u8, @truncate(seed % 52));
            const tmp = deck[i];
            deck[i] = deck[j];
            deck[j] = tmp;
        }

        var card_idx: u8 = 0;
        for (&hg.players, 0..) |*p, p_idx| {
            _ = p_idx;
            p.hand_count = 0;
            var c: u8 = 0;
            while (c < 13) : (c += 1) {
                p.hand[p.hand_count] = deck[card_idx];
                card_idx += 1;
                p.hand_count += 1;
            }
        }
        hg.phase = .playing;
    }

    pub fn selectCard(hg: *HeartsGame, card_index: i8) void {
        if (card_index >= 0 and card_index < hg.players[0].hand_count) {
            hg.selected_card = card_index;
        }
    }

    pub fn playSelectedCard(hg: *HeartsGame) bool {
        if (hg.selected_card < 0 or hg.current_player != 0) return false;
        const card_idx = @as(u8, @intCast(hg.selected_card));
        return hg.playCard(0, card_idx);
    }

    pub fn playCard(hg: *HeartsGame, player_idx: u8, card_idx: u8) bool {
        const player = &hg.players[player_idx];
        if (card_idx >= player.hand_count) return false;

        // Check if valid play (must follow suit if possible)
        if (hg.trick_count > 0) {
            const lead_suit = hg.trick_cards[0].suit;
            const card = player.hand[card_idx];
            var has_suit = false;
            for (player.hand[0..player.hand_count]) |c| {
                if (c.suit == lead_suit) {
                    has_suit = true;
                    break;
                }
            }
            if (has_suit and card.suit != lead_suit) return false;
        }

        // Play the card
        hg.trick_cards[hg.trick_count] = player.hand[card_idx];
        hg.trick_players[hg.trick_count] = player_idx;
        hg.trick_count += 1;

        // Remove from hand
        var i: u8 = card_idx;
        while (i < player.hand_count - 1) : (i += 1) {
            player.hand[i] = player.hand[i + 1];
        }
        player.hand_count -= 1;

        hg.current_player = (hg.current_player + 1) % 4;
        hg.selected_card = -1;

        // If trick is complete, score it
        if (hg.trick_count == 4) {
            hg.scoreTrick();
        }

        return true;
    }

    fn scoreTrick(hg: *HeartsGame) void {
        const lead_suit = hg.trick_cards[0].suit;
        var winner_idx: u8 = 0;
        var highest_value: u8 = @intFromEnum(hg.trick_cards[0].value);

        for (1..4) |i| {
            const card = hg.trick_cards[i];
            if (card.suit == lead_suit and @intFromEnum(card.value) > highest_value) {
                highest_value = @intFromEnum(card.value);
                winner_idx = @as(u8, @intCast(i));
            }
        }

        hg.trick_leader = hg.trick_players[winner_idx];

        // Score: hearts = 1 each, queen of spades = 13, shooting the moon = -26
        var trick_pts: i32 = 0;
        for (hg.trick_cards) |card| {
            if (card.suit == .hearts) trick_pts += 1;
            if (card.suit == .spades and card.value == .queen) trick_pts += 13;
        }

        hg.round_score += trick_pts;
        hg.current_player = hg.trick_leader;
        hg.trick_count = 0;

        // Check if round is over
        if (hg.players[0].hand_count == 0) {
            hg.phase = .round_over;
            for (&hg.players) |*p| {
                p.score += if (p.round_score == 26) -26 else p.round_score;
                p.round_score = 0;
            }
        }
    }

    pub fn aiTakeTurn(hg: *HeartsGame) void {
        if (hg.current_player == 0) return;
        if (hg.phase != .playing) return;

        const player = &hg.players[hg.current_player];
        var card_to_play: u8 = 0;

        if (hg.trick_count == 0) {
            // Lead trick: play low card (preferably not hearts)
            card_to_play = hg.aiSelectLowCard(player, false);
        } else {
            // Follow suit: play lowest matching card
            const lead_suit = hg.trick_cards[0].suit;
            card_to_play = hg.aiSelectMatchingCard(player, lead_suit);
        }

        _ = hg.playCard(hg.current_player, card_to_play);
    }

    fn aiSelectLowCard(player: *Player, avoid_hearts: bool) u8 {
        var best_idx: u8 = 0;
        var best_value: u8 = 15;

        for (0..player.hand_count) |i| {
            const card = player.hand[i];
            const val = @intFromEnum(card.value);
            var score = val;

            if (avoid_hearts and card.suit == .hearts) {
                score += 20;
            }
            if (card.suit == .spades and card.value == .queen) {
                score += 30;
            }

            if (score < best_value) {
                best_value = score;
                best_idx = @as(u8, @intCast(i));
            }
        }
        return best_idx;
    }

    fn aiSelectMatchingCard(player: *Player, lead_suit: HSuit) u8 {
        var best_idx: u8 = 0;
        var best_value: u8 = 15;

        for (0..player.hand_count) |i| {
            const card = player.hand[i];
            if (card.suit == lead_suit) {
                const val = @intFromEnum(card.value);
                if (val < best_value) {
                    best_value = val;
                    best_idx = @as(u8, @intCast(i));
                }
            }
        }
        return best_idx;
    }

    pub fn tick(hg: *HeartsGame) void {
        if (hg.phase == .playing and hg.current_player != 0) {
            hg.aiTakeTurn();
        }
    }

    pub fn render(hg: *HeartsGame, t: *const theme_mod.ThemeColors) void {
        if (!hg.visible) return;
        hg.renderBoard(t);
        hg.renderPlayerHands(t);
        hg.renderTrick(t);
        hg.renderScores(t);
    }

    fn renderBoard(hg: *HeartsGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        fb.fillRect(hg.x, hg.y, hg.width, hg.height, rgb(0x00, 0x50, 0x00));
        var i: usize = 0;
        while (i < 2000) : (i += 1) {
            const px = hg.x + @as(i32, @intCast((i * 7) % hg.width));
            const py = hg.y + @as(i32, @intCast((i * 13) % hg.height));
            fb.putPixel32(px, py, rgb(0x00, 0x40, 0x00));
        }
    }

    fn renderPlayerHands(hg: *HeartsGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const player = &hg.players[0];
        const hand_count = player.hand_count;
        const card_w: i32 = 50;
        const card_h: i32 = 70;
        const total_w = @as(i32, @intCast(hand_count)) * (card_w + 4) - 4;
        const start_x = hg.x + @divTrunc(hg.width - total_w, 2);
        const hand_y = hg.y + hg.height - card_h - 20;

        var c: u8 = 0;
        while (c < hand_count) : (c += 1) {
            const cx = start_x + @as(i32, @intCast(c)) * (card_w + 4);
            const is_selected = @as(i8, @intCast(c)) == hg.selected_card;
            const offset_y: i32 = if (is_selected) -20 else 0;

            const card = player.hand[c];
            const is_red = (card.suit == .hearts or card.suit == .diamonds);

            fb.fillRect(cx, hand_y + offset_y, card_w, card_h, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(cx, hand_y + offset_y, card_w, card_h, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC0, 0xC0));

            const value_str = switch (card.value) {
                .two => "2", .three => "3", .four => "4", .five => "5",
                .six => "6", .seven => "7", .eight => "8", .nine => "9",
                .ten => "10", .jack => "J", .queen => "Q", .king => "K", .ace => "A",
            };
            const suit_color = if (is_red) rgb(0xCC, 0x00, 0x00) else rgb(0x00, 0x00, 0x00);
            fb.drawTextTransparent(cx + 4, hand_y + offset_y + 4, value_str, suit_color);
            fb.drawTextTransparent(cx + 4, hand_y + offset_y + card_h - 20, value_str, suit_color);
        }
    }

    fn renderTrick(hg: *HeartsGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const cx = hg.x + @divTrunc(hg.width, 2) - 25;
        const cy = hg.y + @divTrunc(hg.height, 2) - 35;

        var i: u8 = 0;
        while (i < hg.trick_count) : (i += 1) {
            const card = hg.trick_cards[i];
            const player = hg.trick_players[i];
            const is_red = (card.suit == .hearts or card.suit == .diamonds);

            const card_x: i32 = switch (player) {
                0 => cx - 80,
                1 => cx + 60,
                2 => cx - 80,
                3 => cx - 120,
                else => cx,
            };
            const card_y: i32 = switch (player) {
                0 => cy + 60,
                1 => cy - 100,
                2 => cy - 100,
                3 => cy + 60,
                else => cy,
            };

            fb.fillRect(card_x, card_y, 50, 70, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(card_x, card_y, 50, 70, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC0, 0xC0));

            const value_str = switch (card.value) {
                .two => "2", .three => "3", .four => "4", .five => "5",
                .six => "6", .seven => "7", .eight => "8", .nine => "9",
                .ten => "10", .jack => "J", .queen => "Q", .king => "K", .ace => "A",
            };
            const suit_color = if (is_red) rgb(0xCC, 0x00, 0x00) else rgb(0x00, 0x00, 0x00);
            fb.drawTextTransparent(card_x + 4, card_y + 4, value_str, suit_color);
        }
    }

    fn renderScores(hg: *HeartsGame, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const score_x = hg.x + 10;
        const score_y = hg.y + 10;

        for (0..4) |i| {
            var buf: [64]u8 = undefined;
            const p = &hg.players[i];
            const msg = std.fmt.bufPrint(&buf, "{s}: {d}", .{ p.name[0..p.name_len], p.score }) catch "";
            fb.drawTextTransparent(score_x, score_y + @as(i32, @intCast(i)) * 16, msg, rgb(0xFF, 0xFF, 0xFF));
        }

        // Current turn indicator
        const turn_msg = "Current: You";
        fb.drawTextTransparent(hg.x + hg.width - 120, hg.y + 10, turn_msg, rgb(0xFF, 0xDD, 0x00));
    }
};
