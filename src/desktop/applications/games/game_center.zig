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
// Module: src/desktop/applications/games/game_center.zig
// Purpose: Game Explorer / Game Center main window
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const icons_mod = @import("../../kernel/icons/root.zig");
const dwm_mod = @import("../../../drivers/video/core/dwm.zig");
const game_strings = @import("game_strings.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const GameId = enum(u16) {
    minesweeper = 0,
    solitaire = 1,
    spider_solitaire = 2,
    freecell = 3,
    hearts = 4,
    chess_titans = 5,
    mahjong_titans = 6,
    purble_place = 7,
    _,
};

pub const GameInfo = struct {
    id: GameId,
    name: []const u8,
    description: []const u8,
    category: GameCategory,
    difficulty_levels: u8,
    supports_ai: bool,
    icon_id: icons_mod.IconId,
};

pub const GameCategory = enum(u8) {
    puzzle,
    cards,
    strategy,
    _,
};

pub const GameCenter = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    title: []const u8,
    visible: bool,
    focused: bool,
    selected_game: i32,
    hover_game: i32,
    caption_hover: CaptionButtonType,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) GameCenter {
        return .{
            .x = x_pos,
            .y = y_pos,
            .width = w,
            .height = h,
            .title = game_strings.gameString("game_center_title"),
            .visible = true,
            .focused = false,
            .selected_game = -1,
            .hover_game = -1,
            .caption_hover = .none,
        };
    }

    pub fn render(gc: *GameCenter, t: *const theme_mod.ThemeColors) void {
        if (!gc.visible) return;
        gc.renderWindowFrame(t);
        gc.renderClientArea(t);
    }

    fn renderWindowFrame(gc: *GameCenter, t: *const theme_mod.ThemeColors) void {
        const wx = gc.x;
        const wy = gc.y;
        const ww = gc.width;
        const wh = gc.height;
        const ch: i32 = 32;

        if (dwm_mod.isInitialized() and dwm_mod.getConfig().shadow_enabled) {
            fb.fillRect(wx + 4, wy + 4, ww, wh, rgb(0x28, 0x28, 0x30));
        }

        fb.fillRect(wx, wy + ch, ww, wh - ch, t.window_bg);

        if (dwm_mod.isGlassEnabled()) {
            const active_color = if (gc.focused) t.titlebar_active_left else t.titlebar_inactive_left;
            dwm_mod.renderGlassEffect(wx, wy, ww, ch, active_color, .caption);
        } else {
            fb.drawGradientH(wx, wy, ww, ch, t.titlebar_active_left, t.titlebar_active_right);
        }

        gc.renderCaptionButtons(t);

        const text_x = wx + 8;
        const text_y = wy + @divTrunc(ch - 14, 2);
        const text_color = if (gc.focused) t.titlebar_text else t.titlebar_inactive_text;
        fb.drawTextTransparent(text_x, text_y, gc.title, text_color);

        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    }

    fn renderCaptionButtons(gc: *GameCenter, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = gc.x;
        const wy = gc.y;
        const ww = gc.width;
        const ch: i32 = 32;

        const btn_h = 18;
        const btn_y = wy + @divTrunc(ch - btn_h, 2);
        const btn_w: i32 = 40;
        const btn_w_close: i32 = 48;
        const close_x = wx + ww - btn_w_close;
        const max_x = close_x - btn_w;
        const min_x = max_x - btn_w;

        fb.drawVLine(min_x - 1, wy + 1, ch - 2, rgb(0xB8, 0xD0, 0xE8));
        fb.drawVLine(max_x, wy + 1, ch - 2, rgb(0x3A, 0x5A, 0x78));
        fb.drawVLine(close_x, wy + 1, ch - 2, rgb(0x3A, 0x5A, 0x78));

        if (gc.caption_hover == .close) {
            fb.fillRect(close_x, btn_y, btn_w_close, btn_h, rgb(0xE8, 0x11, 0x23));
        }

        const cx: i32 = close_x + @divTrunc(btn_w_close, 2);
        const cy: i32 = btn_y + @divTrunc(btn_h, 2);
        var d: i32 = -4;
        while (d <= 4) : (d += 1) {
            fb.putPixel32(@intCast(cx + d), @intCast(cy + d), if (gc.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
            fb.putPixel32(@intCast(cx + d), @intCast(cy - d), if (gc.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
        }
    }

    fn renderClientArea(gc: *GameCenter, _: *const theme_mod.ThemeColors) void {
        const cx = gc.x + 4;
        const cy = gc.y + 36;
        const cw = gc.width - 8;
        const ch = gc.height - 40;

        fb.fillRect(cx, cy, cw, ch, rgb(0xF0, 0xF4, 0xF8));

        const header_y = cy + 8;
        fb.drawTextTransparent(cx + 16, header_y, "ZirconOSAero Games", rgb(0x20, 0x40, 0x80));

        const games = getGamesList();
        const item_w: i32 = 160;
        const item_h: i32 = 120;
        const spacing: i32 = 16;

        var item_x = cx + 16;
        var item_y = cy + 40;

        for (games, 0..) |game, idx| {
            if (item_x + item_w > cx + cw - 16) {
                item_x = cx + 16;
                item_y += item_h + spacing;
            }

            const is_hover = @as(i32, @intCast(idx)) == gc.hover_game;
            const is_selected = @as(i32, @intCast(idx)) == gc.selected_game;

            if (is_hover) {
                fb.fillRect(item_x - 2, item_y - 2, item_w + 4, item_h + 4, rgb(0xD0, 0xE0, 0xF0));
            }
            if (is_selected) {
                fb.fillRect(item_x - 4, item_y - 4, item_w + 8, item_h + 8, rgb(0xC0, 0xD8, 0xF0));
                fb.draw3DRect(item_x - 4, item_y - 4, item_w + 8, item_h + 8, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
            }

            fb.fillRect(item_x, item_y, item_w, item_h, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(item_x, item_y, item_w, item_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF0));

            const icon_x = item_x + @divTrunc(item_w - 64, 2);
            fb.fillRect(icon_x, item_y + 10, 64, 48, rgb(0xE8, 0xEC, 0xF4));

            const text_w = @min(@as(i32, @intCast(game.name.len)) * 7, item_w - 16);
            fb.drawTextTransparent(item_x + @divTrunc(item_w - text_w, 2), item_y + 66, game.name, rgb(0x10, 0x20, 0x40));

            item_x += item_w + spacing;
        }
    }

    fn getGamesList() []const GameInfo {
        return &[_]GameInfo{
            .{ .id = .minesweeper, .name = "Minesweeper", .description = "Find the mines without stepping on them", .category = .puzzle, .difficulty_levels = 3, .supports_ai = false, .icon_id = .settings },
            .{ .id = .solitaire, .name = "Solitaire", .description = "Classic card game", .category = .cards, .difficulty_levels = 1, .supports_ai = false, .icon_id = .settings },
            .{ .id = .hearts, .name = "Hearts", .description = "Card game for 4 players", .category = .cards, .difficulty_levels = 1, .supports_ai = true, .icon_id = .settings },
            .{ .id = .chess_titans, .name = "Chess Titans", .description = "3D Chess game", .category = .strategy, .difficulty_levels = 10, .supports_ai = true, .icon_id = .settings },
        };
    }
};
